defmodule Mix.Tasks.Constitution.CheckTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Constitution.Check

  setup do
    root = Path.join(System.tmp_dir!(), "constitution-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "scripts"))
    File.write!(Path.join(root, "CONSTITUTION.md"), "# rules\n")
    File.write!(Path.join(root, "scripts/promote.sh"), "#!/bin/bash\n")

    {_, 0} = System.cmd("git", ["-C", root, "init", "-q"])
    {_, 0} = System.cmd("git", ["-C", root, "-c", "user.email=t@t", "-c", "user.name=t", "add", "."], stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["-C", root, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "init"], stderr_to_stdout: true)

    prior = System.get_env("SYMPHONY_AGENT_LANE")

    on_exit(fn ->
      File.rm_rf(root)

      case prior do
        nil -> System.delete_env("SYMPHONY_AGENT_LANE")
        value -> System.put_env("SYMPHONY_AGENT_LANE", value)
      end
    end)

    %{root: root}
  end

  test "passes outside agent lanes when the constitution is tracked", %{root: root} do
    System.delete_env("SYMPHONY_AGENT_LANE")
    output = capture_io(fn -> Check.run(["--repo-root", root]) end)
    assert output =~ "present and tracked"
  end

  test "passes in agent lanes when protected files are untouched", %{root: root} do
    System.put_env("SYMPHONY_AGENT_LANE", "1")
    output = capture_io(fn -> Check.run(["--repo-root", root]) end)
    assert output =~ "protected invariants untouched"
  end

  test "fails in agent lanes when a protected file is modified", %{root: root} do
    System.put_env("SYMPHONY_AGENT_LANE", "1")
    File.write!(Path.join(root, "CONSTITUTION.md"), "# weakened rules\n")

    output =
      capture_io(:stderr, fn ->
        assert_raise Mix.Error, ~r/may not modify constitution-protected/, fn ->
          Check.run(["--repo-root", root])
        end
      end)

    assert output =~ "CONSTITUTION.md"
  end

  test "fails everywhere when the constitution is missing or untracked", %{root: root} do
    System.delete_env("SYMPHONY_AGENT_LANE")
    File.rm!(Path.join(root, "CONSTITUTION.md"))

    assert_raise Mix.Error, ~r/missing/, fn -> Check.run(["--repo-root", root]) end

    File.write!(Path.join(root, "CONSTITUTION.md"), "# back, but untracked in HEAD is still tracked in index? no: new file\n")
    {_, 0} = System.cmd("git", ["-C", root, "rm", "-q", "--cached", "CONSTITUTION.md"], stderr_to_stdout: true)

    assert_raise Mix.Error, ~r/not tracked/, fn -> Check.run(["--repo-root", root]) end
  end

  test "raises on invalid options" do
    assert_raise Mix.Error, ~r/invalid options/, fn -> Check.run(["--bogus"]) end
  end

  test "the real repo passes and exposes protected paths" do
    assert "CONSTITUTION.md" in Check.protected_paths()
    repo_root = Path.expand("..", File.cwd!())
    System.delete_env("SYMPHONY_AGENT_LANE")
    output = capture_io(fn -> Check.run(["--repo-root", repo_root]) end)
    assert output =~ "constitution"
  end

  test "fails loudly when git status itself fails" do
    assert_raise Mix.Error, ~r/git status failed/, fn ->
      Check.dirty_protected_paths("/anywhere", fn _cmd, _args, _opts -> {"boom", 128} end)
    end

    assert Check.dirty_protected_paths("/anywhere", fn _cmd, _args, _opts -> {" M CONSTITUTION.md\n", 0} end) ==
             ["CONSTITUTION.md"]
  end

  test "CR-001: committed protected-file changes are detected against origin/main" do
    diff_cmd = fn
      "git", ["-C", _root, "rev-parse", "--verify", "origin/main"], _opts -> {"abc123\n", 0}
      "git", ["-C", _root, "diff", "--name-only", "origin/main", "HEAD", "--" | _], _opts -> {"CONSTITUTION.md\n", 0}
    end

    assert Check.committed_protected_changes("/anywhere", diff_cmd) == ["CONSTITUTION.md"]

    no_origin = fn "git", ["-C", _root, "rev-parse" | _], _opts -> {"fatal", 128} end
    assert Check.committed_protected_changes("/anywhere", no_origin) == []

    diff_fails = fn
      "git", ["-C", _root, "rev-parse" | _], _opts -> {"abc\n", 0}
      "git", ["-C", _root, "diff" | _], _opts -> {"boom", 128}
    end

    assert_raise Mix.Error, ~r/git diff failed/, fn ->
      Check.committed_protected_changes("/anywhere", diff_fails)
    end
  end

  test "the checker protects itself" do
    assert "elixir/lib/mix/tasks/constitution.check.ex" in Check.protected_paths()
  end
end
