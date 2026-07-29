defmodule SymphonyElixir.AgentRunnerInstantTurnTest do
  @moduledoc """
  SPEC 11.4 post-completion spin control, mechanism A: instant-turn backoff and bound.

  Production evidence this exists for: with Linear rate-limiting the tracker
  reads, the turn cycle collapsed to ~1.1s (session started 22:26:36.443,
  completed 22:26:37.585). The model was not working - the ticket had genuinely
  finished earlier and it said so immediately - but every such turn re-sent the
  full model context and its boundary refresh hammered the API that was already
  throttling us. Two 15-minute windows measured 181 and 156 sessions with 74
  RATELIMITED errors and 0 recorded completions.

  So: a turn that completes under agent.instant_turn_threshold_ms buys a
  backoff BEFORE the boundary refresh (giving the tracker room to recover so the
  refresh can actually see the terminal state), and
  agent.max_consecutive_instant_turns of them in a row ends the run instead of
  grinding to max_turns.
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
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "test-key",
      instant_turn_threshold_ms: 5_000,
      instant_turn_backoff_ms: 30_000,
      max_consecutive_instant_turns: 3
    )

    {:ok, journal} = Agent.start_link(fn -> [] end)
    {:ok, clock} = Agent.start_link(fn -> 0 end)

    %{journal: journal, clock: clock}
  end

  defp record(journal, event), do: Agent.update(journal, &[event | &1])
  defp events(journal), do: journal |> Agent.get(& &1) |> Enum.reverse()

  # clock_fun is called twice per turn: once before AppServer.run_turn and once
  # after. Even calls return 0 (turn start), odd calls return the scripted
  # duration for that turn, so `elapsed_ms` is exactly the scripted value.
  defp scripted_clock(clock, durations) do
    fn ->
      index = Agent.get_and_update(clock, &{&1, &1 + 1})

      if rem(index, 2) == 0 do
        0
      else
        Enum.at(durations, div(index, 2), List.last(durations))
      end
    end
  end

  defp run_opts(journal, clock, durations, extra) do
    Keyword.merge(
      [
        codex_update_recipient: self(),
        clock_fun: scripted_clock(clock, durations),
        sleep_fun: fn ms -> record(journal, {:sleep, ms}) end,
        run_turn_fun: fn _session, _prompt, _issue, _opts ->
          record(journal, :turn)
          {:ok, %{session_id: "session-1"}}
        end,
        issue_state_fetcher: fn ["issue-1"] ->
          record(journal, :refresh)
          {:ok, [@issue]}
        end
      ],
      extra
    )
  end

  test "a turn slower than the threshold is not instant and never sleeps", %{journal: j, clock: c} do
    assert :ok =
             AgentRunner.run_codex_turns_for_test(
               @issue,
               run_opts(j, c, [10_000, 10_000], max_turns: 2)
             )

    assert events(j) == [:turn, :refresh, :turn, :refresh]
    assert_received {:agent_run_outcome, "issue-1", %{confirmed?: true, reason: :max_turns_active}}
  end

  test "an instant turn backs off the configured amount BEFORE the boundary refresh", %{journal: j, clock: c} do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert :ok =
                 AgentRunner.run_codex_turns_for_test(
                   @issue,
                   run_opts(j, c, [1_100, 1_100], max_turns: 2)
                 )
      end)

    # The sleep must precede the refresh: backing off after the read would leave
    # the read itself inside the throttled window it is supposed to escape.
    assert events(j) == [:turn, {:sleep, 30_000}, :refresh, :turn, {:sleep, 30_000}, :refresh]
    assert log =~ "instant turn for issue_id=issue-1"
    assert log =~ "elapsed_ms=1100"
  end

  test "detection uses agent.instant_turn_threshold_ms, not a hardcoded value", %{journal: j, clock: c} do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "test-key",
      instant_turn_threshold_ms: 1_000,
      instant_turn_backoff_ms: 30_000,
      max_consecutive_instant_turns: 3
    )

    # 2000ms would be instant under the 5s default; under a 1s threshold it is a
    # real turn and must not back off.
    assert :ok =
             AgentRunner.run_codex_turns_for_test(
               @issue,
               run_opts(j, c, [2_000], max_turns: 1)
             )

    assert events(j) == [:turn, :refresh]
  end

  test "a turn exactly at the threshold is not instant (strict less-than)", %{journal: j, clock: c} do
    assert :ok =
             AgentRunner.run_codex_turns_for_test(
               @issue,
               run_opts(j, c, [5_000], max_turns: 1)
             )

    assert events(j) == [:turn, :refresh]
  end

  test "the configured backoff value is what gets slept", %{journal: j, clock: c} do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "test-key",
      instant_turn_threshold_ms: 5_000,
      instant_turn_backoff_ms: 7_500,
      max_consecutive_instant_turns: 3
    )

    ExUnit.CaptureLog.capture_log(fn ->
      assert :ok =
               AgentRunner.run_codex_turns_for_test(
                 @issue,
                 run_opts(j, c, [1_000], max_turns: 1)
               )
    end)

    assert {:sleep, 7_500} in events(j)
  end

  test "max_consecutive_instant_turns ends the run long before max_turns", %{journal: j, clock: c} do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert :ok =
                 AgentRunner.run_codex_turns_for_test(
                   @issue,
                   run_opts(j, c, [1_100], max_turns: 24)
                 )
      end)

    # Three instant turns, two backoffs (the third hits the bound and ends the
    # run immediately) - not 24 turns of paid context re-sends.
    assert Enum.count(events(j), &(&1 == :turn)) == 3
    assert Enum.count(events(j), &match?({:sleep, _}, &1)) == 2
    assert log =~ "after 3 consecutive instant turn(s)"

    # Ending on the instant bound proves nothing about the issue's real state,
    # so the orchestrator must be told the completion is unconfirmed.
    assert_received {:agent_run_outcome, "issue-1", %{confirmed?: false, reason: :instant_turn_bound, issue_state: "In Progress"}}
  end

  test "a real turn resets the consecutive instant counter", %{journal: j, clock: c} do
    ExUnit.CaptureLog.capture_log(fn ->
      assert :ok =
               AgentRunner.run_codex_turns_for_test(
                 @issue,
                 # instant, instant, REAL, instant, instant, instant
                 run_opts(j, c, [1_000, 1_000, 60_000, 1_000, 1_000, 1_000], max_turns: 24)
               )
    end)

    # Without the reset the run would end at turn 3; the real turn at 3 clears
    # the counter and the bound is only reached at turn 6.
    assert Enum.count(events(j), &(&1 == :turn)) == 6
    assert_received {:agent_run_outcome, "issue-1", %{reason: :instant_turn_bound}}
  end

  test "instant turns still respect a terminal state seen after the backoff", %{journal: j, clock: c} do
    fetcher = fn ["issue-1"] ->
      record(j, :refresh)
      {:ok, [%{@issue | state: "Done"}]}
    end

    ExUnit.CaptureLog.capture_log(fn ->
      assert :ok =
               AgentRunner.run_codex_turns_for_test(
                 @issue,
                 run_opts(j, c, [1_000], max_turns: 24, issue_state_fetcher: fetcher)
               )
    end)

    # This is the outcome the backoff exists to buy: one turn, one sleep, and a
    # refresh that finally sees Done instead of spinning.
    assert events(j) == [:turn, {:sleep, 30_000}, :refresh]
    assert_received {:agent_run_outcome, "issue-1", %{confirmed?: true, reason: :terminal}}
  end

  test "an exhausted degraded budget reports an unconfirmed ending, not a completion", %{journal: j, clock: c} do
    fetcher = fn ["issue-1"] ->
      record(j, :refresh)
      {:error, {:tracker_rate_limited, %{status: 429, retry_after_ms: 60_000}}}
    end

    ExUnit.CaptureLog.capture_log(fn ->
      assert :ok =
               AgentRunner.run_codex_turns_for_test(
                 @issue,
                 run_opts(j, c, [60_000], max_turns: 24, issue_state_fetcher: fetcher)
               )
    end)

    # Composes with 850a0fb: one degraded turn, then the run ends - but as
    # UNCONFIRMED, so the orchestrator latches instead of re-dispatching in 1s.
    assert Enum.count(events(j), &(&1 == :turn)) == 2
    assert_received {:agent_run_outcome, "issue-1", %{confirmed?: false, reason: :refresh_exhausted}}
  end
end
