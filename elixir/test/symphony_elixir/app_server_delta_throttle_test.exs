defmodule SymphonyElixir.Codex.AppServerDeltaThrottleTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Codex.AppServer

  defmodule CoordinatorProbe do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    def stats(pid), do: GenServer.call(pid, :stats)

    def init(opts) do
      interval_ms = Keyword.fetch!(opts, :interval_ms)
      Process.send_after(self(), :refresh_snapshot, interval_ms)

      {:ok,
       %{
         interval_ms: interval_ms,
         parent: Keyword.fetch!(opts, :parent),
         notification_count: 0,
         methods: MapSet.new()
       }}
    end

    def handle_call(:stats, _from, state) do
      {:reply, Map.take(state, [:notification_count, :methods]), state}
    end

    def handle_info(:refresh_snapshot, state) do
      send(state.parent, {:snapshot_refreshed, System.monotonic_time(:millisecond)})
      Process.send_after(self(), :refresh_snapshot, state.interval_ms)
      {:noreply, state}
    end

    def handle_info({:app_server_notification, message}, state) do
      {:noreply,
       %{
         state
         | notification_count: state.notification_count + 1,
           methods: MapSet.put(state.methods, get_in(message, [:payload, "method"]))
       }}
    end
  end

  describe "delta notification throttling" do
    test "delta-class methods are detected" do
      assert AppServer.delta_notification_for_test?("item/commandExecution/outputDelta")
      assert AppServer.delta_notification_for_test?("item/agentMessage/delta")
      assert AppServer.delta_notification_for_test?("codex/event/agent_message_delta")
      assert AppServer.delta_notification_for_test?("codex/event/agent_message_content_delta")
      assert AppServer.delta_notification_for_test?("codex/event/agent_reasoning_delta")
      assert AppServer.delta_notification_for_test?("codex/event/reasoning_content_delta")
      assert AppServer.delta_notification_for_test?("codex/event/exec_command_output_delta")
      refute AppServer.delta_notification_for_test?("thread/tokenUsage/updated")
      refute AppServer.delta_notification_for_test?("item/completed")
      refute AppServer.delta_notification_for_test?("codex/event/item_completed")
      refute AppServer.delta_notification_for_test?(nil)
    end

    test "same method emits once per interval, distinct methods are independent" do
      assert AppServer.delta_emission_due_for_test?("item/commandExecution/outputDelta")
      refute AppServer.delta_emission_due_for_test?("item/commandExecution/outputDelta")
      assert AppServer.delta_emission_due_for_test?("item/agentMessage/delta")
      refute AppServer.delta_emission_due_for_test?("item/agentMessage/delta")
    end

    test "throttle re-arms after the interval elapses" do
      assert AppServer.delta_emission_due_for_test?("item/reasoning/outputDelta")
      key = {:codex_delta_last_emit, "item/reasoning/outputDelta"}
      Process.put(key, System.monotonic_time(:millisecond) - 1_001)
      assert AppServer.delta_emission_due_for_test?("item/reasoning/outputDelta")
    end

    test "a synthetic 14-agent delta flood keeps active snapshot cadence within twice the interval" do
      interval_ms = 50
      flood_duration_ms = interval_ms * 5
      method = "codex/event/exec_command_output_delta"
      {:ok, probe} = CoordinatorProbe.start_link(parent: self(), interval_ms: interval_ms)
      on_message = fn message -> send(probe, {:app_server_notification, message}) end

      tasks =
        for agent <- 1..14 do
          Task.async(fn ->
            deadline = System.monotonic_time(:millisecond) + flood_duration_ms
            flood_until(deadline, on_message, method, agent, 0)
          end)
        end

      assert_receive {:snapshot_refreshed, first_refresh}, 1_000
      assert_receive {:snapshot_refreshed, second_refresh}, interval_ms * 4
      assert second_refresh - first_refresh <= interval_ms * 2
      assert Enum.all?(tasks, &(Task.yield(&1, 0) == nil))

      assert Enum.map(tasks, &Task.await(&1, 1_000)) |> Enum.all?(&(&1 > 1))

      assert %{notification_count: 14, methods: methods} =
               wait_for_notifications(probe, 14)

      assert methods == MapSet.new([method])
    end
  end

  defp flood_until(deadline, on_message, method, agent, count) do
    if System.monotonic_time(:millisecond) < deadline do
      AppServer.emit_notification_for_test(on_message, method, %{
        "method" => method,
        "params" => %{"agent" => agent, "delta" => "x"}
      })

      Process.sleep(1)
      flood_until(deadline, on_message, method, agent, count + 1)
    else
      count
    end
  end

  defp wait_for_notifications(probe, expected, attempts \\ 20)

  defp wait_for_notifications(probe, expected, attempts) when attempts > 0 do
    case CoordinatorProbe.stats(probe) do
      %{notification_count: ^expected} = stats ->
        stats

      _stats ->
        Process.sleep(10)
        wait_for_notifications(probe, expected, attempts - 1)
    end
  end

  defp wait_for_notifications(probe, _expected, 0), do: CoordinatorProbe.stats(probe)
end
