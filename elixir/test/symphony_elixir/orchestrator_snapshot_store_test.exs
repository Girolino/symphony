defmodule SymphonyElixir.OrchestratorSnapshotStoreTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.OrchestratorSnapshotStore
  alias SymphonyElixirWeb.Presenter

  test "cached snapshots stay responsive while the orchestrator mailbox is saturated" do
    orchestrator_name = Module.concat(__MODULE__, :BusyOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        if Process.info(pid, :status) == {:status, :suspended}, do: :sys.resume(pid)
        Process.exit(pid, :normal)
      end
    end)

    wait_for_poll_idle(pid)
    started_at = DateTime.add(DateTime.utc_now(), -5, :second)

    running =
      Map.new(1..6, fn index ->
        issue_id = "issue-#{index}"

        {issue_id,
         %{
           pid: self(),
           ref: make_ref(),
           identifier: "MT-#{index}",
           issue: %Issue{id: issue_id, identifier: "MT-#{index}", state: "In Progress"},
           session_id: "thread-#{index}",
           codex_app_server_pid: Integer.to_string(index),
           codex_input_tokens: 0,
           codex_output_tokens: 0,
           codex_total_tokens: 0,
           turn_count: 0,
           started_at: started_at,
           last_codex_timestamp: started_at,
           last_codex_message: nil,
           last_codex_event: :session_started
         }}
      end)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | running: running,
          claimed: MapSet.new(Map.keys(running)),
          poll_check_in_progress: true,
          next_poll_due_at_ms: nil,
          tick_timer_ref: nil,
          tick_token: make_ref()
      }
    end)

    send(pid, {:worker_runtime_info, "issue-1", %{worker_host: "worker-1"}})

    assert %{running: cached_running} = wait_for_cached_snapshot(orchestrator_name, 6)
    assert length(cached_running) == 6

    :sys.suspend(pid)

    Enum.each(1..1_000, fn index ->
      send(pid, {:codex_worker_update, "issue-1", %{event: :notification, timestamp: started_at, raw: index}})
    end)

    started_ms = System.monotonic_time(:millisecond)
    snapshot = Orchestrator.snapshot(orchestrator_name, 1)
    elapsed_ms = System.monotonic_time(:millisecond) - started_ms

    assert elapsed_ms < 50
    assert length(snapshot.running) == 6
    assert snapshot.health.status == "healthy"
    assert snapshot.health.orchestrator_alive
    assert snapshot.health.message_queue_len >= 1_000
    assert snapshot.health.poll_busy, inspect(snapshot.polling)
    assert snapshot.health.snapshot_age_ms >= 0

    assert %{health: %{orchestrator_alive: true}} = Orchestrator.snapshot(pid, 1)

    assert %{
             counts: %{running: 6},
             health: %{orchestrator_alive: true, poll_busy: true}
           } = Presenter.state_payload(orchestrator_name, 1)
  end

  test "last published snapshot reports an unavailable orchestrator after exit" do
    snapshot_key = Module.concat(__MODULE__, :ExitedPublisher)
    parent = self()

    {pid, monitor_ref} =
      spawn_monitor(fn ->
        :ok =
          OrchestratorSnapshotStore.publish(snapshot_key, %{
            running: [],
            retrying: [],
            blocked: [],
            codex_totals: %{},
            rate_limits: nil,
            polling: %{checking?: false, next_poll_in_ms: 30_000, poll_interval_ms: 30_000}
          })

        send(parent, :snapshot_published)
      end)

    assert_receive :snapshot_published
    assert_receive {:DOWN, ^monitor_ref, :process, ^pid, :normal}

    assert {:ok, snapshot} = OrchestratorSnapshotStore.fetch(snapshot_key)
    assert snapshot.health.status == "unavailable"
    refute snapshot.health.orchestrator_alive
    assert snapshot.health.message_queue_len == nil
  end

  defp wait_for_cached_snapshot(orchestrator_name, running_count, attempts \\ 50)

  defp wait_for_cached_snapshot(orchestrator_name, running_count, attempts) when attempts > 0 do
    case Orchestrator.snapshot(orchestrator_name, 50) do
      %{running: running} = snapshot when length(running) == running_count ->
        snapshot

      _ ->
        Process.sleep(10)
        wait_for_cached_snapshot(orchestrator_name, running_count, attempts - 1)
    end
  end

  defp wait_for_cached_snapshot(_orchestrator_name, _running_count, 0), do: flunk("snapshot was not published")

  defp wait_for_poll_idle(pid, attempts \\ 50)

  defp wait_for_poll_idle(pid, attempts) when attempts > 0 do
    case GenServer.call(pid, :snapshot) do
      %{polling: %{checking?: false, next_poll_in_ms: next_poll_in_ms}}
      when is_integer(next_poll_in_ms) and next_poll_in_ms > 1_000 ->
        :ok

      _ ->
        Process.sleep(10)
        wait_for_poll_idle(pid, attempts - 1)
    end
  end

  defp wait_for_poll_idle(_pid, 0), do: flunk("orchestrator did not finish its initial poll")
end
