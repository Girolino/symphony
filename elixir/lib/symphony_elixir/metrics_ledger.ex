defmodule SymphonyElixir.MetricsLedger do
  @moduledoc """
  Append-only ledger for dashboard metrics that must survive orchestrator restarts.
  """

  require Logger

  @default_totals %{
    input_tokens: 0,
    output_tokens: 0,
    total_tokens: 0,
    seconds_running: 0
  }

  @default_ledger_relative_path "metrics/codex_totals.jsonl"

  @spec default_ledger_file(Path.t()) :: Path.t()
  def default_ledger_file(logs_root) when is_binary(logs_root) do
    metrics_root =
      case Path.basename(logs_root) do
        "logs" -> Path.dirname(logs_root)
        _basename -> logs_root
      end

    Path.join(metrics_root, @default_ledger_relative_path)
  end

  @spec load_totals(map()) :: map()
  def load_totals(defaults \\ @default_totals) when is_map(defaults) do
    case ledger_file() do
      nil ->
        normalize_totals(defaults)

      path ->
        path
        |> replay_ledger(normalize_totals(defaults))
        |> normalize_totals()
    end
  end

  @spec append_delta(map()) :: :ok
  def append_delta(delta) when is_map(delta) do
    normalized_delta = normalize_totals(delta)

    if zero_delta?(normalized_delta) do
      :ok
    else
      append_record(%{
        schema: "symphony.codex_totals.delta.v1",
        recorded_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        delta: normalized_delta
      })
    end
  end

  def append_delta(_delta), do: :ok

  defp append_record(record) do
    case ledger_file() do
      nil ->
        :ok

      path ->
        encoded = Jason.encode!(record)

        with :ok <- File.mkdir_p(Path.dirname(path)),
             :ok <- File.write(path, encoded <> "\n", [:append]) do
          :ok
        else
          {:error, reason} ->
            Logger.warning("Failed to append Symphony metrics ledger #{path}: #{inspect(reason)}")
            :ok
        end
    end
  end

  defp replay_ledger(path, totals) do
    if File.regular?(path) do
      path
      |> File.stream!(:line, [])
      |> Enum.reduce(totals, &apply_ledger_line/2)
    else
      totals
    end
  rescue
    error ->
      Logger.warning("Failed to replay Symphony metrics ledger #{path}: #{Exception.message(error)}")
      totals
  end

  defp apply_ledger_line(line, totals) do
    with {:ok, %{"delta" => delta}} <- Jason.decode(String.trim(line)),
         true <- is_map(delta) do
      apply_delta(totals, normalize_totals(delta))
    else
      _ -> totals
    end
  end

  defp apply_delta(totals, delta) do
    %{
      input_tokens: max(0, integer_value(totals, :input_tokens) + integer_value(delta, :input_tokens)),
      output_tokens: max(0, integer_value(totals, :output_tokens) + integer_value(delta, :output_tokens)),
      total_tokens: max(0, integer_value(totals, :total_tokens) + integer_value(delta, :total_tokens)),
      seconds_running: max(0, integer_value(totals, :seconds_running) + integer_value(delta, :seconds_running))
    }
  end

  defp normalize_totals(totals) do
    %{
      input_tokens: integer_value(totals, :input_tokens),
      output_tokens: integer_value(totals, :output_tokens),
      total_tokens: integer_value(totals, :total_tokens),
      seconds_running: integer_value(totals, :seconds_running)
    }
  end

  defp zero_delta?(delta) do
    Enum.all?([:input_tokens, :output_tokens, :total_tokens, :seconds_running], fn key ->
      Map.get(delta, key, 0) == 0
    end)
  end

  defp integer_value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key)) || 0
  end

  defp integer_value(_map, _key), do: 0

  defp ledger_file do
    case Application.get_env(:symphony_elixir, :metrics_ledger_file) do
      path when is_binary(path) and path != "" -> Path.expand(path)
      _ -> nil
    end
  end
end
