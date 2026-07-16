defmodule Mix.Tasks.Constitution.Check do
  use Mix.Task

  @moduledoc """
  Enforces the CONSTITUTION.md boundary: in agent-lane environments
  (`SYMPHONY_AGENT_LANE=1`) the constitution-protected files must be
  untouched relative to HEAD — the system cannot remove its own brakes.
  Outside lane environments it verifies the constitution exists and is
  tracked, so deleting it also fails the gate.

      mix constitution.check [--repo-root path]
  """
  @shortdoc "Fails when agent lanes touch constitution-protected files"

  @switches [repo_root: :string]

  @protected_paths [
    "CONSTITUTION.md",
    ".githooks",
    "scripts/promote.sh",
    "elixir/lib/mix/tasks/constitution.check.ex"
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      Mix.raise("constitution.check: invalid options #{inspect(invalid)}")
    end

    repo_root = opts[:repo_root] || Path.expand("..", File.cwd!())

    unless File.regular?(Path.join(repo_root, "CONSTITUTION.md")) do
      Mix.raise("constitution.check: CONSTITUTION.md is missing at the repo root")
    end

    unless tracked?(repo_root, "CONSTITUTION.md") do
      Mix.raise("constitution.check: CONSTITUTION.md is not tracked by git")
    end

    if agent_lane?() do
      touched =
        dirty_protected_paths(repo_root, &System.cmd/3) ++
          committed_protected_changes(repo_root, &System.cmd/3)

      case Enum.uniq(touched) do
        [] ->
          Mix.shell().info("constitution.check: protected invariants untouched (agent lane)")

        dirty ->
          Enum.each(dirty, &Mix.shell().error("protected file modified in an agent lane: #{&1}"))
          Mix.raise("constitution.check failed: agent lanes may not modify constitution-protected files")
      end
    else
      Mix.shell().info("constitution.check: constitution present and tracked")
    end

    :ok
  end

  @spec protected_paths() :: [String.t()]
  def protected_paths, do: @protected_paths

  defp agent_lane?, do: System.get_env("SYMPHONY_AGENT_LANE") == "1"

  # A worktree-only check would let an agent COMMIT the weakened file and pass
  # (review round CR-001): committed protected-path changes relative to the
  # published origin/main are equally forbidden in agent lanes.
  @doc false
  @type git_cmd :: (String.t(), [String.t()], keyword() -> {String.t(), non_neg_integer()})

  @spec committed_protected_changes(String.t(), git_cmd()) :: [String.t()]
  def committed_protected_changes(repo_root, cmd) do
    case cmd.("git", ["-C", repo_root, "rev-parse", "--verify", "origin/main"], stderr_to_stdout: true) do
      {_out, 0} ->
        case cmd.(
               "git",
               ["-C", repo_root, "diff", "--name-only", "origin/main", "HEAD", "--"] ++ @protected_paths,
               stderr_to_stdout: true
             ) do
          {out, 0} -> String.split(out, "\n", trim: true)
          {out, _nonzero} -> Mix.raise("constitution.check: git diff failed: #{out}")
        end

      _no_origin ->
        # Lanes always have origin; roots without it (fixtures) have nothing published to diff.
        []
    end
  end

  defp tracked?(repo_root, path) do
    case System.cmd("git", ["-C", repo_root, "ls-files", "--error-unmatch", path], stderr_to_stdout: true) do
      {_out, 0} -> true
      _ -> false
    end
  end

  @doc false
  @spec dirty_protected_paths(String.t(), git_cmd()) :: [String.t()]
  def dirty_protected_paths(repo_root, cmd) do
    case cmd.(
           "git",
           ["-C", repo_root, "status", "--porcelain", "--"] ++ @protected_paths,
           stderr_to_stdout: true
         ) do
      {out, 0} ->
        out
        |> String.split("\n", trim: true)
        |> Enum.map(&String.slice(&1, 3..-1//1))

      {out, _nonzero} ->
        Mix.raise("constitution.check: git status failed: #{out}")
    end
  end
end
