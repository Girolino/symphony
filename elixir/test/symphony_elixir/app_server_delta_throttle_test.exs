defmodule SymphonyElixir.Codex.AppServerDeltaThrottleTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Codex.AppServer

  defmodule CadenceProbe do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    def init(opts) do
      interval_ms = Keyword.fetch!(opts, :interval_ms)
      Process.send_after(self(), :refresh_snapshot, interval_ms)

      {:ok,
       %{
         interval_ms: interval_ms,
         parent: Keyword.fetch!(opts, :parent)
       }}
    end

    def handle_info(:refresh_snapshot, state) do
      send(state.parent, {:snapshot_refreshed, System.monotonic_time(:millisecond)})
      Process.send_after(self(), :refresh_snapshot, state.interval_ms)
      {:noreply, state}
    end

    def handle_info({:delta, _agent, _index}, state), do: {:noreply, state}
  end

  describe "delta notification throttling" do
    test "delta-class methods are detected" do
      assert AppServer.delta_notification_for_test?("item/commandExecution/outputDelta")
      assert AppServer.delta_notification_for_test?("item/agentMessage/delta")
      refute AppServer.delta_notification_for_test?("thread/tokenUsage/updated")
      refute AppServer.delta_notification_for_test?("item/completed")
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

    test "a synthetic 14-agent delta flood keeps snapshot cadence within twice the interval" do
      interval_ms = 100
      {:ok, probe} = CadenceProbe.start_link(parent: self(), interval_ms: interval_ms)

      tasks =
        for agent <- 1..14 do
          Task.async(fn ->
            Enum.reduce(1..1_000, 0, fn index, emitted ->
              if AppServer.delta_emission_due_for_test?("item/commandExecution/outputDelta") do
                send(probe, {:delta, agent, index})
                emitted + 1
              else
                emitted
              end
            end)
          end)
        end

      assert Enum.map(tasks, &Task.await(&1, 1_000)) == List.duplicate(1, 14)
      assert_receive {:snapshot_refreshed, first_refresh}, 1_000
      assert_receive {:snapshot_refreshed, second_refresh}, interval_ms * 4
      assert second_refresh - first_refresh <= interval_ms * 2
    end
  end
end
