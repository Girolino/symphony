defmodule SymphonyElixir.AgentRunnerRefreshTest do
  @moduledoc """
  Turn-boundary issue-state refresh tolerance (SPEC 11.4).

  A tracker read failure at the turn boundary must never fail an agent run: the
  Codex turn is already paid for, and failing the run makes the orchestrator
  re-dispatch the whole context.
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

  defp recorder do
    {:ok, pid} = Agent.start_link(fn -> [] end)
    {pid, fn ms -> Agent.update(pid, &[ms | &1]) end}
  end

  test "a refresh failure followed by success continues with the refreshed issue" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    {delays, sleep_fun} = recorder()

    fetcher = fn ["issue-1"] ->
      n = Agent.get_and_update(counter, fn c -> {c, c + 1} end)

      if n < 1 do
        {:error, {:linear_api_status, 500}}
      else
        {:ok, [%{@issue | title: "refreshed"}]}
      end
    end

    assert {:continue, %Issue{title: "refreshed", state: "In Progress"}} =
             AgentRunner.continue_with_issue_for_test(@issue, fetcher, sleep_fun: sleep_fun)

    assert Agent.get(delays, &Enum.reverse/1) == [2_000]
  end

  test "a persistently failing refresh degrades to the stale snapshot, never an error" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    {delays, sleep_fun} = recorder()

    fetcher = fn ["issue-1"] ->
      Agent.update(counter, &(&1 + 1))
      {:error, {:linear_api_status, 500}}
    end

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:continue, issue} =
                 AgentRunner.continue_with_issue_for_test(@issue, fetcher, sleep_fun: sleep_fun)

        assert issue == @issue
      end)

    assert log =~ "continuing with the stale issue snapshot"
    # bounded: 3 attempts total, 2 backoffs (2s then 4s)
    assert Agent.get(counter, & &1) == 3
    assert Agent.get(delays, &Enum.reverse/1) == [2_000, 4_000]
  end

  test "a rate-limit error honors retry_after_ms from the adapter error shape" do
    {delays, sleep_fun} = recorder()

    fetcher = fn ["issue-1"] ->
      {:error, {:tracker_rate_limited, %{status: 429, retry_after_ms: 5_000}}}
    end

    assert {:continue, _issue} =
             AgentRunner.continue_with_issue_for_test(@issue, fetcher, sleep_fun: sleep_fun)

    assert Agent.get(delays, &Enum.reverse/1) == [5_000, 5_000]
  end

  test "retry_after_ms is clamped so a hostile hint cannot stall the turn loop" do
    assert AgentRunner.refresh_backoff_ms(1, {:tracker_rate_limited, %{retry_after_ms: 600_000}}) == 8_000
    assert AgentRunner.refresh_backoff_ms(1, {:linear_api_status, 500}) == 2_000
    assert AgentRunner.refresh_backoff_ms(2, {:linear_api_status, 500}) == 4_000
  end

  test "a terminal state on refresh still ends the run" do
    fetcher = fn ["issue-1"] -> {:ok, [%{@issue | state: "Done"}]} end

    assert {:done, %Issue{state: "Done"}} =
             AgentRunner.continue_with_issue_for_test(@issue, fetcher, sleep_fun: fn _ -> :ok end)
  end

  test "an empty refresh result still ends the run with the known issue" do
    fetcher = fn ["issue-1"] -> {:ok, []} end

    assert {:done, issue} =
             AgentRunner.continue_with_issue_for_test(@issue, fetcher, sleep_fun: fn _ -> :ok end)

    assert issue == @issue
  end

  test "an auth failure defers immediately without burning retries" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    fetcher = fn ["issue-1"] ->
      Agent.update(counter, &(&1 + 1))
      {:error, {:linear_api_status, 401}}
    end

    assert {:defer, {:linear_api_status, 401}} =
             AgentRunner.continue_with_issue_for_test(@issue, fetcher, sleep_fun: fn _ -> :ok end)

    assert Agent.get(counter, & &1) == 1
  end
end
