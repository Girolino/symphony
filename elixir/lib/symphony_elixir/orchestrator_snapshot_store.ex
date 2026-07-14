defmodule SymphonyElixir.OrchestratorSnapshotStore do
  @moduledoc """
  Lock-free public reads of the orchestrator's last published state.

  The orchestrator remains the only authority that builds snapshots. Published
  snapshots live in ETS so API and dashboard readers never add synchronous
  calls to the orchestrator mailbox while tracker or worker traffic is busy.
  """

  use GenServer

  @table __MODULE__
  @minimum_stale_after_ms 5_000

  @type health :: %{
          status: String.t(),
          snapshot_age_ms: non_neg_integer(),
          stale_after_ms: pos_integer(),
          published_at: String.t(),
          orchestrator_alive: boolean(),
          message_queue_len: non_neg_integer() | nil,
          poll_busy: boolean()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec publish(GenServer.server(), map()) :: :ok
  def publish(orchestrator, snapshot) when is_map(snapshot) do
    case :ets.whereis(@table) do
      :undefined ->
        :ok

      _table ->
        published_at_ms = System.monotonic_time(:millisecond)
        published_at = DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()

        rows =
          [orchestrator, self()]
          |> Enum.uniq()
          |> Enum.map(&{&1, self(), published_at_ms, published_at, snapshot})

        :ets.insert(@table, rows)
        :ok
    end
  end

  @spec fetch(GenServer.server()) :: {:ok, map()} | :missing
  def fetch(orchestrator) do
    case lookup(orchestrator) do
      [{_key, publisher, published_at_ms, published_at, snapshot}] ->
        {:ok, refresh_snapshot(snapshot, publisher, published_at_ms, published_at)}

      [] ->
        :missing
    end
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    {:ok, %{}}
  end

  defp lookup(orchestrator) do
    case :ets.whereis(@table) do
      :undefined -> []
      _table -> :ets.lookup(@table, orchestrator)
    end
  end

  defp refresh_snapshot(snapshot, publisher, published_at_ms, published_at) do
    now_ms = System.monotonic_time(:millisecond)
    age_ms = max(now_ms - published_at_ms, 0)
    alive? = Process.alive?(publisher)
    stale_after_ms = stale_after_ms(snapshot)

    snapshot
    |> refresh_running_runtime()
    |> refresh_poll_countdown(age_ms)
    |> Map.put(:health, %{
      status: health_status(alive?, age_ms, stale_after_ms),
      snapshot_age_ms: age_ms,
      stale_after_ms: stale_after_ms,
      published_at: published_at,
      orchestrator_alive: alive?,
      message_queue_len: message_queue_len(publisher, alive?),
      poll_busy: get_in(snapshot, [:polling, :checking?]) == true
    })
  end

  defp refresh_running_runtime(%{running: running} = snapshot) when is_list(running) do
    now = DateTime.utc_now()

    running =
      Enum.map(running, fn
        %{started_at: %DateTime{} = started_at} = entry ->
          Map.put(entry, :runtime_seconds, max(DateTime.diff(now, started_at, :second), 0))

        entry ->
          entry
      end)

    %{snapshot | running: running}
  end

  defp refresh_running_runtime(snapshot), do: snapshot

  defp refresh_poll_countdown(%{polling: polling} = snapshot, age_ms) when is_map(polling) do
    polling =
      case Map.get(polling, :next_poll_in_ms) do
        next_poll_in_ms when is_integer(next_poll_in_ms) ->
          Map.put(polling, :next_poll_in_ms, max(next_poll_in_ms - age_ms, 0))

        _ ->
          polling
      end

    %{snapshot | polling: polling}
  end

  defp refresh_poll_countdown(snapshot, _age_ms), do: snapshot

  defp stale_after_ms(snapshot) do
    poll_interval_ms = get_in(snapshot, [:polling, :poll_interval_ms])

    if is_integer(poll_interval_ms) and poll_interval_ms > 0 do
      max(poll_interval_ms * 2, @minimum_stale_after_ms)
    else
      @minimum_stale_after_ms
    end
  end

  defp health_status(false, _age_ms, _stale_after_ms), do: "unavailable"
  defp health_status(true, age_ms, stale_after_ms) when age_ms > stale_after_ms, do: "stale"
  defp health_status(true, _age_ms, _stale_after_ms), do: "healthy"

  defp message_queue_len(_publisher, false), do: nil

  defp message_queue_len(publisher, true) do
    case Process.info(publisher, :message_queue_len) do
      {:message_queue_len, count} -> count
      nil -> nil
    end
  end
end
