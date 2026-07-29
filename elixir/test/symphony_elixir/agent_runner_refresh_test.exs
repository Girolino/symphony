defmodule SymphonyElixir.AgentRunnerRefreshTest do
  @moduledoc """
  Turn-boundary issue-state refresh tolerance (SPEC 11.4).

  A tracker read failure at the turn boundary must never fail an agent run: the
  Codex turn is already paid for, and failing the run makes the orchestrator
  re-dispatch the whole context. Degrading to the stale snapshot is bounded,
  because a stale snapshot blinds terminal-state and role-boundary detection.
  """

  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentRunner
  alias SymphonyElixir.Linear.Issue

  @issue %Issue{
    id: "issue-1",
    identifier: "SYM-1",
    title: "t",
    description: "d",
    state: "In Progress",
    url: "https://example.org/SYM-1",
    labels: []
  }

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: "test-key")
    :ok
  end

  test "a successful refresh continues with the refreshed issue" do
    fetcher = fn ["issue-1"] -> {:ok, [%{@issue | title: "refreshed"}]} end

    assert {:continue, %Issue{title: "refreshed", state: "In Progress"}} =
             AgentRunner.continue_with_issue_for_test(@issue, fetcher)
  end

  test "a failing refresh degrades to the stale snapshot without retrying the fetcher" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    fetcher = fn ["issue-1"] ->
      Agent.update(counter, &(&1 + 1))
      {:error, {:linear_api_status, 500}}
    end

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:degraded_continue, issue} =
                 AgentRunner.continue_with_issue_for_test(@issue, fetcher)

        assert issue == @issue
      end)

    assert log =~ "continuing with the stale issue snapshot"

    # No turn-boundary retry loop: the tracker adapter owns rate-limit handling and
    # already retries with backoff. Layering a second loop here multiplies both the
    # request count against a throttling API and the blocking time the orchestrator
    # stall watchdog reads as a hung run.
    assert Agent.get(counter, & &1) == 1
  end

  test "a rate-limited refresh degrades exactly like any other tracker read failure" do
    fetcher = fn ["issue-1"] ->
      {:error, {:tracker_rate_limited, %{status: 429, retry_after_ms: 60_000}}}
    end

    assert {:degraded_continue, _issue} = AgentRunner.continue_with_issue_for_test(@issue, fetcher)
  end

  # SPEC 11.4 post-completion spin control: the exhausted budget ends the run as :unconfirmed, not :done.
  # Nothing proved the issue reached a terminal state - only that we stopped
  # being able to look - and the orchestrator must latch re-dispatch on that
  # distinction instead of treating it as a finished run.
  test "the degraded-continue budget is bounded: a second blind boundary ends the run unconfirmed" do
    fetcher = fn ["issue-1"] -> {:error, {:linear_api_status, 500}} end

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:unconfirmed, issue} =
                 AgentRunner.continue_with_issue_for_test(@issue, fetcher, degraded_turns: 1)

        assert issue == @issue
      end)

    assert log =~ "ending the run so the orchestrator poll loop reconciles"
  end

  test "a terminal state on refresh still ends the run" do
    fetcher = fn ["issue-1"] -> {:ok, [%{@issue | state: "Done"}]} end

    assert {:done, %Issue{state: "Done"}} = AgentRunner.continue_with_issue_for_test(@issue, fetcher)
  end

  test "an empty refresh result still ends the run with the known issue" do
    fetcher = fn ["issue-1"] -> {:ok, []} end

    assert {:done, issue} = AgentRunner.continue_with_issue_for_test(@issue, fetcher)
    assert issue == @issue
  end

  test "an auth failure defers immediately instead of degrading" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    fetcher = fn ["issue-1"] ->
      Agent.update(counter, &(&1 + 1))
      {:error, {:linear_api_status, 401}}
    end

    assert {:defer, {:linear_api_status, 401}} =
             AgentRunner.continue_with_issue_for_test(@issue, fetcher)

    assert Agent.get(counter, & &1) == 1
  end
end
