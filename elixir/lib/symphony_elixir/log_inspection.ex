defmodule SymphonyElixir.LogInspection do
  @moduledoc """
  Summarizes Symphony rotating log files for upkeep inspection.
  """

  alias SymphonyElixir.LogFile

  @type source :: :runtime | :test
  @type pattern_name :: :errors | :warnings | :retry | :breaker_or_park | :stall | :linear_auth_401
  @type summary :: %{
          source: source(),
          base_path: Path.t(),
          files: [Path.t()],
          total_lines: non_neg_integer(),
          patterns: %{required(pattern_name()) => non_neg_integer()},
          identifiers: [{String.t(), non_neg_integer()}]
        }

  @patterns [
    errors: ~r/\berror:/i,
    warnings: ~r/\bwarning:/i,
    retry: ~r/\b(?:retry|retrying|retryable|backing off)\b/i,
    breaker_or_park: ~r/\b(?:breaker|park|parked|parking)\b/i,
    stall: ~r/\b(?:stall|stalled|stalling)\b/i,
    linear_auth_401: ~r/(?:linear_api_status,\s*401|status=401|HTTP 401|AUTHENTICATION_ERROR|Linear auth)/i
  ]
  @empty_patterns @patterns |> Keyword.keys() |> Map.new(&{&1, 0})
  @identifier_pattern ~r/issue_identifier=([A-Z][A-Z0-9]*-[A-Z0-9][A-Z0-9-]*)/
  @default_identifier_limit 10

  @spec summarize(source(), keyword()) :: summary()
  def summarize(source, opts \\ []) when source in [:runtime, :test] do
    base_path =
      opts
      |> Keyword.get(:path)
      |> Kernel.||(default_base_path(source, Keyword.get(opts, :logs_root)))
      |> Path.expand()

    files = log_files(base_path)
    identifier_limit = Keyword.get(opts, :identifier_limit, @default_identifier_limit)

    files
    |> Enum.reduce(initial_summary(source, base_path), &summarize_file/2)
    |> finalize_summary(files, identifier_limit)
  end

  @spec default_base_path(source(), Path.t() | nil) :: Path.t()
  def default_base_path(:runtime, logs_root) do
    logs_root
    |> default_logs_root()
    |> LogFile.default_log_file()
  end

  def default_base_path(:test, logs_root) do
    logs_root
    |> default_logs_root()
    |> Path.join("log/test/symphony.log")
  end

  defp default_logs_root(nil), do: File.cwd!()
  defp default_logs_root(logs_root), do: logs_root

  defp log_files(base_path) do
    base_dir = Path.dirname(base_path)
    base_name = Path.basename(base_path)

    base_dir
    |> Path.join("#{base_name}*")
    |> Path.wildcard()
    |> Enum.filter(&log_data_file?/1)
    |> Enum.sort()
  end

  defp log_data_file?(path) do
    File.regular?(path) and not String.ends_with?(path, [".idx", ".siz"])
  end

  defp initial_summary(source, base_path) do
    %{
      source: source,
      base_path: base_path,
      files: [],
      total_lines: 0,
      patterns: @empty_patterns,
      identifier_counts: %{}
    }
  end

  defp summarize_file(path, summary) do
    path
    |> File.stream!()
    |> Enum.reduce(summary, &summarize_line/2)
  end

  defp summarize_line(line, summary) do
    %{
      summary
      | total_lines: summary.total_lines + 1,
        patterns: count_patterns(line, summary.patterns),
        identifier_counts: count_identifiers(line, summary.identifier_counts)
    }
  end

  defp count_patterns(line, counts) do
    Enum.reduce(@patterns, counts, fn {name, pattern}, acc ->
      if Regex.match?(pattern, line), do: Map.update!(acc, name, &(&1 + 1)), else: acc
    end)
  end

  defp count_identifiers(line, counts) do
    @identifier_pattern
    |> Regex.scan(line, capture: :all_but_first)
    |> List.flatten()
    |> Enum.reduce(counts, fn identifier, acc -> Map.update(acc, identifier, 1, &(&1 + 1)) end)
  end

  defp finalize_summary(summary, files, identifier_limit) do
    identifiers =
      summary.identifier_counts
      |> Enum.sort_by(fn {identifier, count} -> {-count, identifier} end)
      |> Enum.take(max(identifier_limit, 0))

    summary
    |> Map.put(:files, files)
    |> Map.put(:identifiers, identifiers)
    |> Map.delete(:identifier_counts)
  end
end
