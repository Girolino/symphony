defmodule Mix.Tasks.Docs.CheckTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Docs.Check
  alias SymphonyElixir.DocsCheck

  setup do
    root = Path.join(System.tmp_dir!(), "docs-check-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "elixir/lib/mix/tasks"))
    File.mkdir_p!(Path.join(root, "docs"))
    File.write!(Path.join(root, "elixir/Makefile"), "all: ci\n\nprod-smoke:\n\ttrue\n")
    File.write!(Path.join(root, "elixir/lib/mix/tasks/prod.smoke.ex"), "# task module\n")
    File.write!(Path.join(root, "SPEC.md"), "## 17. Checks\n\n### 17.8 Real Integration\n")
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root}
  end

  test "passes on alive references", %{root: root} do
    File.write!(Path.join(root, "AGENTS.md"), """
    Run `make prod-smoke` then `mix prod.smoke`.
    See SPEC.md §17.8. Root lives at #{root}.
    """)

    assert DocsCheck.findings(DocsCheck.default_doc_paths(root), repo_root: root) == []

    output = capture_io(fn -> Check.run(["--repo-root", root]) end)
    assert output =~ "all doc references are alive"
  end

  test "flags dead paths, targets, tasks, and sections; prose is ignored", %{root: root} do
    File.write!(Path.join(root, "docs/stale.md"), """
    This should make sense in prose without findings.
    Dead path: #{System.user_home!()}/nonexistent-docs-check-xyz/missing
    Dead fence:
    ```bash
    make bogus-target
    mix bogus.task
    ```
    Dead inline: `make prod-smoke` is fine but SPEC.md §99.9 is not.
    """)

    findings = DocsCheck.findings(DocsCheck.default_doc_paths(root), repo_root: root)
    kinds = findings |> Enum.map(& &1.kind) |> Enum.sort()
    assert kinds == [:make_target, :mix_task, :path, :spec_section]

    output =
      capture_io(:stderr, fn ->
        assert_raise Mix.Error, ~r/4 dead reference/, fn ->
          Check.run(["--repo-root", root])
        end
      end)

    assert output =~ "bogus-target"
    assert output =~ "bogus.task"
    assert output =~ "§99.9"
  end

  test "honors exemptions file", %{root: root} do
    doc = Path.join(root, "docs/intentional.md")
    File.write!(doc, "Planned home: #{System.user_home!()}/nonexistent-docs-check-xyz/future\n")

    exemptions = Path.join(root, ".docs-check-exemptions")
    File.write!(exemptions, "# planned paths\n#{doc}:1\n")

    output = capture_io(fn -> Check.run(["--repo-root", root, "--exemptions-file", exemptions]) end)
    assert output =~ "all doc references are alive"
  end

  test "default exemptions file at repo root is picked up automatically", %{root: root} do
    doc = Path.join(root, "docs/intentional.md")
    File.write!(doc, "Planned home: #{System.user_home!()}/nonexistent-docs-check-xyz/future\n")
    File.write!(Path.join(root, ".docs-check-exemptions"), "#{doc}\n")

    output = capture_io(fn -> Check.run(["--repo-root", root]) end)
    assert output =~ "all doc references are alive"
  end

  test "raises on invalid options" do
    assert_raise Mix.Error, ~r/invalid options/, fn ->
      Check.run(["--bogus"])
    end
  end

  test "foreign-user absolute paths are documentation, not dead references" do
    root = Path.join(System.tmp_dir!(), "docs-foreign-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "docs"))
    on_exit(fn -> File.rm_rf(root) end)
    File.write!(Path.join(root, "docs/env.md"), "Runs at /Users/someone-else/deploy/root\n")

    assert DocsCheck.findings(DocsCheck.default_doc_paths(root), repo_root: root) == []
  end

  test "the real repo docs are currently alive" do
    repo_root = Path.expand("..", File.cwd!())

    assert DocsCheck.findings(DocsCheck.default_doc_paths(repo_root), repo_root: repo_root) == []
  end

  test "missing Makefile and SPEC.md yield empty allowlists, and defaults work" do
    empty_root = Path.join(System.tmp_dir!(), "docs-check-empty-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(empty_root, "docs"))
    on_exit(fn -> File.rm_rf(empty_root) end)

    File.write!(Path.join(empty_root, "docs/only.md"), """
    ```bash
    make anything
    ```
    See §1.2 too.
    """)

    findings = DocsCheck.findings(DocsCheck.default_doc_paths(empty_root), repo_root: empty_root)
    kinds = findings |> Enum.map(& &1.kind) |> Enum.sort()
    assert kinds == [:make_target, :spec_section]

    # Zero-arg default (cwd-derived repo root) also runs against the real repo.
    assert DocsCheck.findings(DocsCheck.default_doc_paths(Path.expand("..", File.cwd!()))) == []
  end
end
