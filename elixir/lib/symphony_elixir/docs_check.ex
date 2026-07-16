defmodule SymphonyElixir.DocsCheck do
  @moduledoc """
  Doc-freshness linter (REVIEW.md rule RV-C3): encoded knowledge that rots
  silently becomes confident misinformation for agents. Checks, per scoped
  doc file:

  * absolute `/Users/...` paths still exist on this host,
  * `make <target>` mentions resolve to real targets in `elixir/Makefile`,
  * custom `mix <ns>.<task>` mentions resolve to real task modules,
  * `§N[.M]` spec-section references exist as headings in `SPEC.md`.

  Exemptions use `file:line` or bare `file` entries — the specs.check shape.
  """

  @type finding :: %{
          file: String.t(),
          line: pos_integer(),
          kind: :path | :make_target | :mix_task | :spec_section,
          detail: String.t()
        }

  @spec findings([Path.t()], keyword()) :: [finding()]
  def findings(doc_paths, opts \\ []) do
    repo_root = Keyword.get(opts, :repo_root, default_repo_root())
    exemptions = opts |> Keyword.get(:exemptions, []) |> MapSet.new()
    make_targets = make_targets(Path.join(repo_root, "elixir/Makefile"))
    mix_tasks = mix_task_names(Path.join(repo_root, "elixir/lib/mix/tasks"))
    spec_sections = spec_sections(Path.join(repo_root, "SPEC.md"))

    doc_paths
    |> Enum.filter(&File.regular?/1)
    |> Enum.flat_map(&file_findings(&1, make_targets, mix_tasks, spec_sections))
    |> Enum.reject(&exempted?(&1, exemptions))
    |> Enum.sort_by(&{&1.file, &1.line, &1.kind})
  end

  @spec default_doc_paths(Path.t()) :: [Path.t()]
  def default_doc_paths(repo_root) do
    [
      Path.join(repo_root, "AGENTS.md"),
      Path.join(repo_root, "REVIEW.md"),
      Path.join(repo_root, "SPEC.md"),
      Path.join(repo_root, "elixir/AGENTS.md")
      | Path.wildcard(Path.join(repo_root, "docs/*.md"))
    ]
  end

  defp file_findings(file, make_targets, mix_tasks, spec_sections) do
    {findings, _in_fence} =
      file
      |> File.read!()
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.reduce({[], false}, fn {text, line}, {acc, in_fence} ->
        in_fence = if String.starts_with?(String.trim_leading(text), "```"), do: not in_fence, else: in_fence
        code = code_segments(text, in_fence)

        found =
          path_findings(file, line, text) ++
            make_findings(file, line, code, make_targets) ++
            mix_findings(file, line, code, mix_tasks) ++
            section_findings(file, line, text, spec_sections)

        {acc ++ found, in_fence}
      end)

    findings
  end

  # Command references only count inside code: whole fenced lines, or inline
  # backtick spans — "make sense" in prose is not a make target.
  defp code_segments(text, true), do: text

  defp code_segments(text, false) do
    ~r/`([^`]+)`/
    |> Regex.scan(text)
    |> Enum.map_join(" ", fn [_, span] -> span end)
  end

  # Only paths under the RUNNING user's home are verifiable on this machine;
  # foreign paths are environment documentation, not dead references, and must
  # not fail the gate on other hosts (CR-002). The pattern is derived from the
  # actual home so detection is portable across macOS (/Users) and Linux CI
  # (/home) — a hardcoded /Users regex silently detected nothing on Linux.
  defp path_findings(file, line, text) do
    home = System.user_home!()
    home_pattern = ~r/(#{Regex.escape(home)}\/[A-Za-z0-9._\/\-]+)/

    home_pattern
    |> Regex.scan(text)
    |> Enum.map(fn [_, path] -> String.trim_trailing(path, ".") end)
    |> Enum.uniq()
    |> Enum.reject(&File.exists?/1)
    |> Enum.map(&%{file: file, line: line, kind: :path, detail: &1})
  end

  defp make_findings(file, line, text, make_targets) do
    ~r/\bmake ([a-z][a-z0-9\-]*)\b/
    |> Regex.scan(text)
    |> Enum.map(fn [_, target] -> target end)
    |> Enum.uniq()
    |> Enum.reject(&MapSet.member?(make_targets, &1))
    |> Enum.map(&%{file: file, line: line, kind: :make_target, detail: "make #{&1}"})
  end

  defp mix_findings(file, line, text, mix_tasks) do
    ~r/\bmix ([a-z][a-z0-9_]*\.[a-z][a-z0-9_.]*)\b/
    |> Regex.scan(text)
    |> Enum.map(fn [_, task] -> task end)
    |> Enum.uniq()
    |> Enum.reject(&(MapSet.member?(mix_tasks, &1) or builtin_mix_task?(&1)))
    |> Enum.map(&%{file: file, line: line, kind: :mix_task, detail: "mix #{&1}"})
  end

  defp section_findings(file, line, text, spec_sections) do
    ~r/§\s?(\d+(?:\.\d+)?)/
    |> Regex.scan(text)
    |> Enum.map(fn [_, section] -> section end)
    |> Enum.uniq()
    |> Enum.reject(&MapSet.member?(spec_sections, &1))
    |> Enum.map(&%{file: file, line: line, kind: :spec_section, detail: "SPEC.md §#{&1}"})
  end

  defp make_targets(makefile) do
    entries =
      if File.regular?(makefile) do
        ~r/^([a-z][a-z0-9\-]*):/m
        |> Regex.scan(File.read!(makefile))
        |> Enum.map(fn [_, target] -> target end)
      else
        []
      end

    MapSet.new(entries)
  end

  defp mix_task_names(tasks_dir) do
    tasks_dir
    |> Path.join("*.ex")
    |> Path.wildcard()
    |> Enum.map(&(&1 |> Path.basename(".ex")))
    |> MapSet.new()
  end

  defp spec_sections(spec_path) do
    entries =
      if File.regular?(spec_path) do
        ~r/^#+\s+(?:Appendix\s+)?(\d+(?:\.\d+)?)[\s.]/m
        |> Regex.scan(File.read!(spec_path))
        |> Enum.map(fn [_, section] -> section end)
      else
        []
      end

    MapSet.new(entries)
  end

  # Builtin/deps mix tasks legitimately referenced in docs.
  @builtin_tasks ~w(deps.get escript.build help.compile local.hex phx.server)
  defp builtin_mix_task?(task), do: task in @builtin_tasks

  defp exempted?(%{file: file, line: line}, exemptions) do
    MapSet.member?(exemptions, "#{file}:#{line}") or MapSet.member?(exemptions, file)
  end

  defp default_repo_root, do: Path.expand("..", File.cwd!())
end
