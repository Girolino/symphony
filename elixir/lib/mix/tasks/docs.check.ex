defmodule Mix.Tasks.Docs.Check do
  use Mix.Task

  alias SymphonyElixir.DocsCheck

  @moduledoc """
  Fails when scoped docs reference dead paths, unknown make/mix targets, or
  nonexistent SPEC.md sections (REVIEW.md rule RV-C3).

      mix docs.check [--repo-root path] [--exemptions-file path]
  """
  @shortdoc "Fails when docs reference dead paths, targets, or spec sections"

  @switches [repo_root: :string, exemptions_file: :string]

  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      Mix.raise("docs.check: invalid options #{inspect(invalid)}")
    end

    repo_root = opts[:repo_root] || Path.expand("..", File.cwd!())

    exemptions =
      case Keyword.get(opts, :exemptions_file, default_exemptions_file(repo_root)) do
        nil -> []
        path -> load_exemptions(path)
      end

    findings =
      repo_root
      |> DocsCheck.default_doc_paths()
      |> DocsCheck.findings(repo_root: repo_root, exemptions: exemptions)

    if findings == [] do
      Mix.shell().info("docs.check: all doc references are alive")
      :ok
    else
      Enum.each(findings, fn finding ->
        Mix.shell().error("#{finding.file}:#{finding.line} dead #{finding.kind}: #{finding.detail}")
      end)

      Mix.raise("docs.check failed with #{length(findings)} dead reference(s) — see REVIEW.md RV-C3")
    end
  end

  defp default_exemptions_file(repo_root) do
    path = Path.join(repo_root, ".docs-check-exemptions")
    if File.exists?(path), do: path, else: nil
  end

  defp load_exemptions(path) do
    if File.exists?(path) do
      path
      |> File.read!()
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    else
      []
    end
  end
end
