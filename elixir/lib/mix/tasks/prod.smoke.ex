defmodule Mix.Tasks.Prod.Smoke do
  use Mix.Task

  alias SymphonyElixir.ProdSmoke

  @moduledoc """
  Runs the production smoke journey against real Linear and a real Codex turn.

  Boots the compiled escript with a disposable workflow, waits for the smoke
  issue to be completed by a real agent turn, asserts `/api/v1/state` and the
  dashboard, cleans up, and writes a machine-readable report.

      mix prod.smoke [--port 4799] [--timeout-ms 900000] [--report-dir path]
                     [--team-key SYM]

  Exits non-zero on FAIL so callers (promote script, lanes) can gate on it.
  """
  @shortdoc "Runs the real production smoke journey (Linear + Codex)"

  @switches [
    port: :integer,
    timeout_ms: :integer,
    report_dir: :string,
    team_key: :string,
    escript_path: :string
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      Mix.raise("prod.smoke: invalid options #{inspect(invalid)}")
    end

    {:ok, _apps} = Application.ensure_all_started(:req)
    runner = Application.get_env(:symphony_elixir, :prod_smoke_runner, ProdSmoke)

    case runner.run(opts) do
      {:ok, report} ->
        Mix.shell().info("prod.smoke PASS in #{report.duration_ms}ms")

      {:error, report} ->
        Mix.shell().error("prod.smoke FAIL: #{report.failure}")
        exit({:shutdown, 1})
    end
  end
end
