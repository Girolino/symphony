defmodule SymphonyElixir.Codex.AppServerDeltaThrottleTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Codex.AppServer

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
  end
end
