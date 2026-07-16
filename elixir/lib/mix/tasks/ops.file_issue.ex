defmodule Mix.Tasks.Ops.FileIssue do
  use Mix.Task

  alias SymphonyElixir.OpsIssue

  @moduledoc """
  Files (or finds) a deduplicated operational Linear issue.

      mix ops.file_issue --title "promote FAIL on <sha>" --body-file report.json
      mix ops.file_issue --title "..." --body "inline body" [--team-key SYME2E]
                         [--project-slug symphony-xxxx]

  Dedupes by exact title among open issues in the team: re-filing the same
  failure returns the existing issue instead of creating a duplicate. Exits
  non-zero only when the issue could not be filed at all.
  """
  @shortdoc "Files a deduplicated operational Linear issue"

  @switches [
    title: :string,
    body: :string,
    body_file: :string,
    team_key: :string,
    project_slug: :string
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      Mix.raise("ops.file_issue: invalid options #{inspect(invalid)}")
    end

    title = opts[:title] || Mix.raise("ops.file_issue: --title is required")
    body = resolve_body(opts)

    {:ok, _apps} = Application.ensure_all_started(:req)
    filer = Application.get_env(:symphony_elixir, :ops_issue_filer, OpsIssue)

    case filer.file(title, body, Keyword.take(opts, [:team_key, :project_slug])) do
      {:created, issue} ->
        Mix.shell().info("ops.file_issue created #{issue["identifier"]} #{issue["url"]}")

      {:existing, issue} ->
        Mix.shell().info("ops.file_issue found existing #{issue["identifier"]} #{issue["url"]}")

      {:error, reason} ->
        Mix.shell().error("ops.file_issue failed: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  defp resolve_body(opts) do
    cond do
      is_binary(opts[:body]) -> opts[:body]
      is_binary(opts[:body_file]) -> File.read!(opts[:body_file])
      true -> Mix.raise("ops.file_issue: --body or --body-file is required")
    end
  end
end
