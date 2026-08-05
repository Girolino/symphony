defmodule Mix.Tasks.Logs.Inspect do
  use Mix.Task

  alias SymphonyElixir.LogInspection

  @moduledoc """
  Inspects Symphony runtime or test log files for upkeep-relevant patterns.

      mix logs.inspect [--source runtime|test] [--logs-root path] [--path path] [--top count]

  The default source is `runtime`, which scans `log/symphony.log*` under the
  selected logs root. Use `--source test` only when intentionally inspecting
  synthetic fixture logs under `log/test/symphony.log*`.
  """
  @shortdoc "Inspects Symphony runtime log patterns separately from test logs"

  @switches [source: :string, logs_root: :string, path: :string, top: :integer]
  @default_source :runtime
  @default_identifier_limit 10

  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      Mix.raise("logs.inspect: invalid options #{inspect(invalid)}")
    end

    source = parse_source(Keyword.get(opts, :source, Atom.to_string(@default_source)))
    identifier_limit = Keyword.get(opts, :top, @default_identifier_limit)

    summary =
      LogInspection.summarize(source,
        logs_root: Keyword.get(opts, :logs_root),
        path: Keyword.get(opts, :path),
        identifier_limit: identifier_limit
      )

    print_summary(summary)
  end

  defp parse_source("runtime"), do: :runtime
  defp parse_source("test"), do: :test
  defp parse_source(source), do: Mix.raise("logs.inspect: invalid --source #{inspect(source)}")

  defp print_summary(summary) do
    Mix.shell().info("logs.inspect: source=#{summary.source} base_path=#{summary.base_path}")
    Mix.shell().info("files=#{length(summary.files)} total_lines=#{summary.total_lines}")
    Mix.shell().info("patterns #{format_patterns(summary.patterns)}")
    Mix.shell().info("top_identifiers #{format_identifiers(summary.identifiers)}")
  end

  defp format_patterns(patterns) do
    [
      :errors,
      :warnings,
      :retry,
      :breaker_or_park,
      :stall,
      :linear_auth_401
    ]
    |> Enum.map_join(" ", fn name -> "#{name}=#{Map.fetch!(patterns, name)}" end)
  end

  defp format_identifiers([]), do: "none"

  defp format_identifiers(identifiers) do
    Enum.map_join(identifiers, " ", fn {identifier, count} -> "#{identifier}=#{count}" end)
  end
end
