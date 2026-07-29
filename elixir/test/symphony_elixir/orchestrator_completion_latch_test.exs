defmodule SymphonyElixir.OrchestratorCompletionLatchTest do
  @moduledoc """
  SPEC 11.4 post-completion spin control, mechanism B: the unconfirmed-completion re-dispatch latch.

  Production evidence: 23-38 dispatches per 15 minutes for the SAME issues,
  74 RATELIMITED errors, 0 recorded completions. The runs were ending because
  Linear would not confirm the terminal state, and the orchestrator's
  @continuation_retry_delay_ms path re-dispatched them one second later - which
  is correct after a run that ended on a fresh read showing the issue active,
  and a feedback loop after a run that ended blind.

  So an unconfirmed ending keeps the issue's claim (the poll loop skips claimed
  issues) and pushes its next dispatch eligibility out by a real backoff that
  escalates while the endings stay unconfirmed, capped at
  agent.max_retry_backoff_ms. The latch is resolved by the fresh tracker read
  the retry itself performs - no extra orchestrator state, no timer to clear.
  """

  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.Linear.Issue

  @issue_id "issue-1"

  @issue %Issue{
    id: @issue_id,
    identifier: "SYM-1",
    title: "t",
    state: "In Progress",
    url: "https://example.org/SYM-1",
    labels: [],
    blocked_by: []
  }

  setup do
    Application.put_env(
      :symphony_elixir,
      :metrics_ledger_file,
      Path.join(System.tmp_dir!(), "latch-ledger-#{System.unique_integer([:positive])}.json")
    )

    :ok
  end

  defp write_config!(overrides) do
    write_workflow_file!(
      Workflow.workflow_file_path(),
      Keyword.merge(
        [
          tracker_kind: "memory",
          tracker_api_token: "token",
          max_concurrent_agents: 1,
          tracker_active_states: ["Todo", "In Progress", "In Review"]
        ],
        overrides
      )
    )
  end

  defp base_state(overrides) do
    struct(
      %Orchestrator.State{
        server_name: Module.concat(__MODULE__, :"S#{System.unique_integer([:positive])}"),
        poll_interval_ms: 60_000,
        max_concurrent_agents: 1,
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
      },
      overrides
    )
  end

  defp running_entry(ref, extra) do
    Map.merge(
      %{
        pid: self(),
        ref: ref,
        identifier: "SYM-1",
        issue: @issue,
        worker_host: nil,
        workspace_path: nil,
        session_id: "session-1",
        last_codex_event: nil,
        last_codex_message: nil,
        retry_attempt: 0,
        retry_failures: 0,
        unconfirmed_endings: 0,
        run_outcome: nil,
        agent_run_lease: nil,
        started_at: DateTime.utc_now()
      },
      extra
    )
  end

  # Drives a normal agent exit through the real :DOWN path and returns the
  # scheduled retry entry plus the delay the orchestrator actually chose.
  defp agent_down_retry(run_outcome, extra \\ %{}) do
    ref = make_ref()

    state =
      base_state(
        running: %{@issue_id => running_entry(ref, Map.merge(extra, %{run_outcome: run_outcome}))},
        claimed: MapSet.new([@issue_id])
      )

    before_ms = System.monotonic_time(:millisecond)
    {:noreply, state} = Orchestrator.handle_info({:DOWN, ref, :process, self(), :normal}, state)
    entry = Map.get(state.retry_attempts, @issue_id)

    if is_reference(entry[:timer_ref]), do: Process.cancel_timer(entry.timer_ref)

    {state, entry, entry.due_at_ms - before_ms}
  end

  test "the runner's outcome report lands on the running entry" do
    write_config!([])
    ref = make_ref()
    state = base_state(running: %{@issue_id => running_entry(ref, %{})})

    outcome = %{confirmed?: false, reason: :instant_turn_bound, issue_state: "In Progress"}

    assert {:noreply, state} =
             Orchestrator.handle_info({:agent_run_outcome, @issue_id, outcome}, state)

    assert state.running[@issue_id].run_outcome == outcome
  end

  test "a confirmed ending keeps the fast 1s continuation check" do
    write_config!([])

    {state, entry, delay_ms} =
      agent_down_retry(%{confirmed?: true, reason: :max_turns_active, issue_state: "In Progress"})

    assert delay_ms <= 1_100
    assert entry.unconfirmed_endings == 0
    # still claimed: the poll loop must not race the scheduled retry
    assert MapSet.member?(state.claimed, @issue_id)
  end

  test "an unconfirmed ending latches re-dispatch to the configured backoff" do
    write_config!(unconfirmed_completion_backoff_ms: 300_000)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        {state, entry, delay_ms} =
          agent_down_retry(%{
            confirmed?: false,
            reason: :instant_turn_bound,
            issue_state: "In Progress"
          })

        # ~5 minutes, not the 1s continuation path that produced 23-38
        # dispatches per 15 minutes in production.
        assert delay_ms > 295_000
        assert delay_ms <= 305_000
        assert entry.unconfirmed_endings == 1
        assert entry.last_issue_state == "In Progress"
        assert MapSet.member?(state.claimed, @issue_id)
        assert state.running == %{}
      end)

    assert log =~ "ended without a confirmed terminal state"
  end

  test "every unconfirmed ending reason latches, including the degraded and defer paths" do
    write_config!(unconfirmed_completion_backoff_ms: 300_000)

    for reason <- [:instant_turn_bound, :refresh_exhausted, :refresh_deferred, :max_turns_stale, :response_timeout] do
      ExUnit.CaptureLog.capture_log(fn ->
        {_state, entry, delay_ms} =
          agent_down_retry(%{confirmed?: false, reason: reason, issue_state: "In Progress"})

        assert delay_ms > 290_000, "#{reason} did not latch"
        assert entry.unconfirmed_endings == 1
      end)
    end
  end

  test "repeated unconfirmed endings escalate" do
    write_config!(unconfirmed_completion_backoff_ms: 60_000, max_retry_backoff_ms: 600_000)

    ExUnit.CaptureLog.capture_log(fn ->
      {_state, entry, delay_ms} =
        agent_down_retry(
          %{confirmed?: false, reason: :instant_turn_bound, issue_state: "In Progress"},
          %{unconfirmed_endings: 2}
        )

      assert entry.unconfirmed_endings == 3
      # 60s * 2^(3-1)
      assert delay_ms > 235_000
      assert delay_ms <= 245_000
    end)
  end

  test "escalation is capped at agent.max_retry_backoff_ms" do
    write_config!(unconfirmed_completion_backoff_ms: 60_000, max_retry_backoff_ms: 600_000)

    assert Orchestrator.unconfirmed_completion_delay(1) == 60_000
    assert Orchestrator.unconfirmed_completion_delay(2) == 120_000
    assert Orchestrator.unconfirmed_completion_delay(4) == 480_000
    # 60s * 2^4 = 960s would exceed the cap
    assert Orchestrator.unconfirmed_completion_delay(5) == 600_000
    assert Orchestrator.unconfirmed_completion_delay(50) == 600_000
  end

  test "an unconfirmed ending never advances the circuit breaker" do
    write_config!(unconfirmed_completion_backoff_ms: 300_000, max_consecutive_failures: 1)

    ExUnit.CaptureLog.capture_log(fn ->
      {state, entry, _delay_ms} =
        agent_down_retry(%{
          confirmed?: false,
          reason: :instant_turn_bound,
          issue_state: "In Progress"
        })

      # A tracker that will not answer is not the ISSUE failing; parking it
      # would file a bogus ops issue for every throttled window.
      assert entry.failures == 0
      assert state.parked == %{}
    end)
  end

  defp latched_state(token) do
    base_state(
      running: %{"other" => running_entry(make_ref(), %{identifier: "SYM-9"})},
      claimed: MapSet.new([@issue_id, "other"]),
      retry_attempts: %{
        @issue_id => %{
          attempt: 1,
          failures: 0,
          timer_ref: nil,
          retry_token: token,
          due_at_ms: 0,
          identifier: "SYM-1",
          error: nil,
          worker_host: nil,
          workspace_path: nil,
          unconfirmed_endings: 2,
          last_issue_state: "In Progress"
        }
      }
    )
  end

  defp fire_retry(tracker_issues) do
    Application.put_env(:symphony_elixir, :memory_tracker_issues, tracker_issues)
    token = make_ref()

    {:noreply, state} =
      Orchestrator.handle_info({:retry_issue, @issue_id, token}, latched_state(token))

    entry = Map.get(state.retry_attempts, @issue_id)
    if is_reference(entry[:timer_ref]), do: Process.cancel_timer(entry.timer_ref)

    {state, entry}
  end

  describe "the latch is resolved by the tracker read the retry performs" do
    # Occupy the single agent slot with an unrelated issue so the retry takes
    # the no-slots reschedule branch: this exercises the real read + resolution
    # without spawning a Codex agent.
    test "a read showing the issue moved to another active state clears the latch" do
      write_config!(unconfirmed_completion_backoff_ms: 300_000)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          {_state, entry} = fire_retry([%{@issue | state: "In Review"}])

          assert entry.unconfirmed_endings == 0
          assert entry.last_issue_state == "In Review"
          # back on the ordinary failure backoff, not the 5-minute latch
          assert entry.due_at_ms - System.monotonic_time(:millisecond) < 300_000
        end)

      assert log =~ "Clearing unconfirmed-completion latch"
    end

    test "a read showing the issue terminal releases the claim outright" do
      write_config!(unconfirmed_completion_backoff_ms: 300_000)

      ExUnit.CaptureLog.capture_log(fn ->
        Application.put_env(:symphony_elixir, :memory_tracker_issues, [%{@issue | state: "Done"}])
        token = make_ref()

        {:noreply, state} =
          Orchestrator.handle_info({:retry_issue, @issue_id, token}, latched_state(token))

        refute Map.has_key?(state.retry_attempts, @issue_id)
        refute MapSet.member?(state.claimed, @issue_id)
      end)
    end

    test "a read showing the same active state keeps the latch and its escalation" do
      write_config!(unconfirmed_completion_backoff_ms: 300_000, max_retry_backoff_ms: 3_600_000)

      ExUnit.CaptureLog.capture_log(fn ->
        {_state, entry} = fire_retry([@issue])

        # An unchanged active state is not evidence the earlier ending was a
        # false alarm, so the counter survives and the next wait escalates.
        assert entry.unconfirmed_endings == 2
        assert entry.due_at_ms - System.monotonic_time(:millisecond) > 500_000
      end)
    end
  end

  test "resolve_unconfirmed_latch leaves a never-latched issue on the normal delays" do
    write_config!([])

    metadata = Orchestrator.resolve_unconfirmed_latch_for_test(@issue, %{unconfirmed_endings: 0})

    refute Map.has_key?(metadata, :delay_type)
    assert Orchestrator.retry_delay_for_test(1, metadata) == 10_000
  end
end
