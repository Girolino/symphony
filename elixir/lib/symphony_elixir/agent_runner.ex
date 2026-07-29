defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in its workspace with Codex.
  """

  require Logger
  alias SymphonyElixir.{AgentRunLease, Config, PromptBuilder, Tracker, Workspace}
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.Linear.{Client, Issue}

  @type worker_host :: String.t() | nil

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    # The orchestrator owns host retries so one worker lifetime never hops machines.
    worker_host = selected_worker_host(Keyword.get(opts, :worker_host), Config.settings!().worker.ssh_hosts)

    Logger.info("Starting agent run for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  defp run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
    Logger.info("Starting worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case Keyword.get(opts, :agent_run_lease) do
      %{path: path, token: token} = lease when is_binary(path) and is_binary(token) ->
        run_with_acquired_lease(lease, issue, codex_update_recipient, opts, worker_host)

      _ ->
        acquire_and_run(issue, codex_update_recipient, opts, worker_host)
    end
  end

  defp acquire_and_run(issue, codex_update_recipient, opts, worker_host) do
    case AgentRunLease.acquire(issue, worker_host) do
      {:ok, lease} ->
        run_with_acquired_lease(lease, issue, codex_update_recipient, opts, worker_host)

      :busy ->
        Logger.info("Skipping agent run for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}; another Symphony session holds the active run lease")
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_with_acquired_lease(lease, issue, codex_update_recipient, opts, worker_host) do
    do_run_on_worker_host(issue, codex_update_recipient, opts, worker_host)
  after
    AgentRunLease.release(lease)
  end

  defp do_run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
    case Workspace.create_for_issue(issue, worker_host) do
      {:ok, workspace} ->
        send_worker_runtime_info(codex_update_recipient, issue, worker_host, workspace)

        try do
          case Workspace.run_before_run_hook(workspace, issue, worker_host) do
            :ok ->
              run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host)

            {:skip, reason} ->
              Logger.info("Skipping agent run for #{issue_context(issue)} after before_run hook request: #{inspect(reason)}")
              :ok

            {:error, reason} ->
              {:error, reason}
          end
        after
          Workspace.run_after_run_hook(workspace, issue, worker_host)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp codex_message_handler(recipient, issue) do
    fn message ->
      send_codex_update(recipient, issue, message)
    end
  end

  defp send_codex_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:codex_worker_update, issue_id, message})
    :ok
  end

  defp send_codex_update(_recipient, _issue, _message), do: :ok

  defp send_worker_runtime_info(recipient, %Issue{id: issue_id}, worker_host, workspace)
       when is_binary(issue_id) and is_pid(recipient) and is_binary(workspace) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         worker_host: worker_host,
         workspace_path: workspace
       }}
    )

    :ok
  end

  defp send_worker_runtime_info(_recipient, _issue, _worker_host, _workspace), do: :ok

  # The orchestrator cannot tell a run that ended because the issue is provably
  # finished from one that ended because the tracker would not say. Both look
  # like a normal task exit, and the second one - re-dispatched a second later -
  # is the post-completion spin: 181 sessions in 15 minutes with 0 recorded
  # completions and 74 RATELIMITED errors. So the runner reports which of the
  # two it was; absence of the report means "confirmed" (skip paths, hook skips)
  # and keeps the message optional.
  defp end_run(ctx, issue, confirmed?, reason, issue_state \\ nil) do
    send_run_outcome(ctx.codex_update_recipient, issue, %{
      confirmed?: confirmed?,
      reason: reason,
      issue_state: issue_state || issue_state_of(issue)
    })

    :ok
  end

  defp send_run_outcome(recipient, %Issue{id: issue_id}, outcome)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:agent_run_outcome, issue_id, outcome})
    :ok
  end

  defp send_run_outcome(_recipient, _issue, _outcome), do: :ok

  defp issue_state_of(%Issue{state: state}), do: state
  defp issue_state_of(_issue), do: nil

  # SPEC 11.4: a running-state refresh failure must never kill an in-flight agent
  # run. A completed Codex turn is already-paid-for model spend; discarding it
  # because Linear rate-limited a read costs a full-context re-send on retry.
  #
  # There is deliberately NO retry loop here. The tracker adapter owns rate-limit
  # handling (SPEC 11.4) and Linear.Client already retries with backoff under an
  # enforced total budget; a second loop on top multiplies both the request count
  # against an API that is throttling us and the blocking time at the turn
  # boundary - long enough for the orchestrator stall watchdog
  # (codex.stall_timeout_ms) to read the silence as a hung run and kill it, which
  # is exactly the paid-turn loss this code exists to prevent.
  #
  # Degrading to the stale snapshot is bounded: a stale snapshot makes both
  # terminal-state and role-boundary detection blind (role_boundary_crossed?
  # would compare the snapshot's state to itself), so after @max_degraded_turns
  # consecutive blind boundaries the run ends and the orchestrator poll loop -
  # which sees fresh state - reconciles.
  @max_degraded_turns 1

  defp run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host) do
    agent_config = Config.settings!().agent
    max_turns = Keyword.get(opts, :max_turns, agent_config.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)

    with {:ok, session} <- AppServer.start_session(workspace, worker_host: worker_host) do
      ctx =
        build_turn_ctx(
          session,
          workspace,
          codex_update_recipient,
          Keyword.put(opts, :issue_state_fetcher, issue_state_fetcher),
          agent_config
        )

      try do
        do_run_codex_turns(ctx, issue, initial_turn(max_turns))
      after
        AppServer.stop_session(session)
      end
    end
  end

  defp initial_turn(max_turns), do: %{number: 1, max: max_turns, degraded: 0, instant: 0}

  defp build_turn_ctx(session, workspace, codex_update_recipient, opts, agent_config) do
    %{
      app_session: session,
      workspace: workspace,
      codex_update_recipient: codex_update_recipient,
      opts: opts,
      issue_state_fetcher: Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1),
      run_turn_fun: Keyword.get(opts, :run_turn_fun, &AppServer.run_turn/4),
      sleep_fun: Keyword.get(opts, :sleep_fun, &Process.sleep/1),
      clock_fun: Keyword.get(opts, :clock_fun, fn -> System.monotonic_time(:millisecond) end),
      instant_turn_threshold_ms: agent_config.instant_turn_threshold_ms,
      instant_turn_backoff_ms: agent_config.instant_turn_backoff_ms,
      max_consecutive_instant_turns: agent_config.max_consecutive_instant_turns
    }
  end

  @doc false
  @spec run_codex_turns_for_test(Issue.t(), keyword()) :: :ok | {:error, term()}
  def run_codex_turns_for_test(issue, opts) do
    agent_config = Config.settings!().agent
    max_turns = Keyword.get(opts, :max_turns, agent_config.max_turns)

    ctx =
      build_turn_ctx(
        Keyword.get(opts, :app_session, %{session_id: "test-session", thread_id: "test-thread"}),
        Keyword.get(opts, :workspace, "/tmp/test-workspace"),
        Keyword.get(opts, :codex_update_recipient),
        opts,
        agent_config
      )

    do_run_codex_turns(ctx, issue, initial_turn(max_turns))
  end

  defp do_run_codex_turns(ctx, issue, %{number: turn_number, max: max_turns} = turn) do
    prompt = build_turn_prompt(issue, ctx.opts, turn_number, max_turns)
    turn_started_at_ms = ctx.clock_fun.()

    case ctx.run_turn_fun.(
           ctx.app_session,
           prompt,
           issue,
           on_message: codex_message_handler(ctx.codex_update_recipient, issue)
         ) do
      {:ok, turn_session} ->
        elapsed_ms = ctx.clock_fun.() - turn_started_at_ms

        Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{ctx.workspace} turn=#{turn_number}/#{max_turns} elapsed_ms=#{elapsed_ms}")

        handle_completed_turn(ctx, issue, turn_session, turn, elapsed_ms)

      {:error, :response_timeout} when turn_number > 1 ->
        Logger.warning(
          "follow-up Codex turn start failed for #{issue_context(issue)} thread_id=#{ctx.app_session[:thread_id]} turn=#{turn_number}/#{max_turns}: :response_timeout; returning control to orchestrator continuation retry"
        )

        end_run(ctx, issue, false, :response_timeout)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # SPEC 11.4 post-completion spin control, mechanism A. Measured in production: when Linear throttles the
  # tracker reads, the turn cycle collapses to ~1.1s (22:26:36.443 start ->
  # 22:26:37.585 complete). The model is not working - the ticket genuinely
  # finished earlier and it says so immediately - but each such turn re-sends
  # the full context and its boundary refresh hammers the API that is already
  # rate-limiting us. So a turn that completed under the threshold buys a
  # backoff before the boundary refresh (giving the tracker room to recover, so
  # the refresh has a chance to actually see the terminal state), and a bounded
  # number of them in a row ends the run instead of grinding through max_turns.
  defp handle_completed_turn(ctx, issue, turn_session, %{instant: instant_turns} = turn, elapsed_ms) do
    if instant_turn?(ctx, elapsed_ms) do
      handle_instant_turn(ctx, issue, turn_session, turn, elapsed_ms, instant_turns + 1)
    else
      handle_turn_boundary(ctx, issue, turn_session, %{turn | instant: 0})
    end
  end

  defp handle_instant_turn(ctx, issue, turn_session, %{number: turn_number, max: max_turns} = turn, elapsed_ms, instant_turns) do
    max_instant = ctx.max_consecutive_instant_turns

    if instant_turns >= max_instant do
      Logger.warning(
        "ending agent run for #{issue_context(issue)} after #{instant_turns} consecutive instant turn(s) " <>
          "(last elapsed_ms=#{elapsed_ms} < agent.instant_turn_threshold_ms=#{ctx.instant_turn_threshold_ms}) " <>
          "turn=#{turn_number}/#{max_turns}; the model has nothing left to do and the terminal state is unconfirmed"
      )

      end_run(ctx, issue, false, :instant_turn_bound)
    else
      Logger.warning(
        "instant turn for #{issue_context(issue)} elapsed_ms=#{elapsed_ms} < " <>
          "agent.instant_turn_threshold_ms=#{ctx.instant_turn_threshold_ms} " <>
          "instant=#{instant_turns}/#{max_instant}; backing off #{ctx.instant_turn_backoff_ms}ms before the turn boundary"
      )

      ctx.sleep_fun.(ctx.instant_turn_backoff_ms)

      handle_turn_boundary(ctx, issue, turn_session, %{turn | instant: instant_turns})
    end
  end

  defp instant_turn?(ctx, elapsed_ms) when is_integer(elapsed_ms) do
    threshold = ctx.instant_turn_threshold_ms
    is_integer(threshold) and threshold > 0 and elapsed_ms < threshold
  end

  defp instant_turn?(_ctx, _elapsed_ms), do: false

  defp handle_turn_boundary(ctx, issue, turn_session, %{number: turn_number, max: max_turns, degraded: degraded_turns} = turn) do
    case continue_with_issue?(issue, ctx.issue_state_fetcher, degraded_turns) do
      {:continue, refreshed_issue} when turn_number < max_turns ->
        continue_or_end_at_role_boundary(ctx, issue, refreshed_issue, turn)

      {:continue, refreshed_issue} ->
        Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; returning control to orchestrator")

        end_run(ctx, refreshed_issue, true, :max_turns_active)

      {:degraded_continue, stale_issue} when turn_number < max_turns ->
        continue_on_stale_snapshot(ctx, stale_issue, turn)

      {:degraded_continue, stale_issue} ->
        Logger.info("Reached agent.max_turns for #{issue_context(stale_issue)} on a stale snapshot; returning control to orchestrator")

        end_run(ctx, stale_issue, false, :max_turns_stale)

      {:done, refreshed_issue} ->
        end_run(ctx, refreshed_issue, true, :terminal)

      {:unconfirmed, stale_issue} ->
        end_run(ctx, stale_issue, false, :refresh_exhausted)

      {:defer, reason} ->
        Logger.warning(
          "post-turn issue-state refresh failed for #{issue_context(issue)} session_id=#{turn_session[:session_id]}: " <>
            "#{inspect(reason)}; returning control to orchestrator continuation retry"
        )

        end_run(ctx, issue, false, :refresh_deferred)
    end
  end

  # The snapshot is stale, so terminal-state and role-boundary detection are both
  # blind this turn. Continue anyway - the completed turn is already paid for -
  # and let @max_degraded_turns end the run if the next boundary cannot refresh
  # either, so a cancelled issue cannot keep burning turns unnoticed.
  defp continue_on_stale_snapshot(ctx, stale_issue, %{number: turn_number, max: max_turns, degraded: degraded_turns} = turn) do
    Logger.warning(
      "continuing agent run for #{issue_context(stale_issue)} on a stale issue snapshot " <>
        "turn=#{turn_number}/#{max_turns} degraded=#{degraded_turns + 1}/#{@max_degraded_turns}; " <>
        "terminal-state and role-boundary detection are blind until a refresh succeeds"
    )

    do_run_codex_turns(ctx, stale_issue, %{turn | number: turn_number + 1, degraded: degraded_turns + 1})
  end

  defp continue_or_end_at_role_boundary(ctx, issue, refreshed_issue, %{number: turn_number, max: max_turns} = turn) do
    if role_boundary_crossed?(issue.state, refreshed_issue.state) do
      Logger.info("Ending session at role boundary for #{issue_context(refreshed_issue)}: #{inspect(issue.state)} -> #{inspect(refreshed_issue.state)}; a fresh session will own the new role")

      end_run(ctx, refreshed_issue, true, :role_boundary)
    else
      Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns}")

      # a successful refresh clears the degraded budget: the bound is on
      # consecutive blind boundaries, not on the run as a whole
      do_run_codex_turns(ctx, refreshed_issue, %{turn | number: turn_number + 1, degraded: 0})
    end
  end

  @doc false
  @spec role_boundary_crossed?(String.t() | nil, String.t() | nil) :: boolean()
  def role_boundary_crossed?(start_state, current_state)
      when is_binary(start_state) and is_binary(current_state) do
    boundaries =
      Config.settings!().agent.role_boundary_states
      |> Enum.map(&normalize_issue_state/1)
      |> MapSet.new()

    start_n = normalize_issue_state(start_state)
    current_n = normalize_issue_state(current_state)

    current_n != start_n and
      (MapSet.member?(boundaries, current_n) or MapSet.member?(boundaries, start_n))
  end

  def role_boundary_crossed?(_start_state, _current_state), do: false

  defp build_turn_prompt(issue, opts, 1, _max_turns), do: PromptBuilder.build_prompt(issue, opts)

  defp build_turn_prompt(_issue, _opts, turn_number, max_turns) do
    """
    Continuation guidance:

    - The previous Codex turn completed normally, but the Linear issue is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
  end

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher, degraded_turns)
       when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if active_issue_state?(refreshed_issue.state) do
          {:continue, refreshed_issue}
        else
          {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        cond do
          Client.auth_failure?(reason) ->
            {:defer, reason}

          degraded_turns < @max_degraded_turns ->
            Logger.warning(
              "post-turn issue-state refresh failed for #{issue_context(issue)}: #{inspect(reason)}; " <>
                "continuing with the stale issue snapshot per SPEC 11.4 instead of failing the run"
            )

            {:degraded_continue, issue}

          true ->
            Logger.warning(
              "post-turn issue-state refresh failed for #{issue_context(issue)}: #{inspect(reason)} " <>
                "after #{degraded_turns} degraded turn(s); ending the run so the orchestrator poll loop " <>
                "reconciles instead of burning more turns blind"
            )

            # NOT {:done, _}: nothing confirmed this issue reached a terminal
            # state, only that we stopped being able to look. The orchestrator
            # must latch it out of immediate re-dispatch (SPEC 11.4 post-completion spin control, mechanism B)
            # rather than treat it as a finished run.
            {:unconfirmed, issue}
        end
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher, _degraded_turns), do: {:done, issue}

  @doc false
  @spec continue_with_issue_for_test(Issue.t(), (list() -> term()), keyword()) ::
          {:continue, Issue.t()}
          | {:degraded_continue, Issue.t()}
          | {:done, Issue.t()}
          | {:unconfirmed, Issue.t()}
          | {:defer, term()}
  def continue_with_issue_for_test(issue, issue_state_fetcher, opts \\ []) do
    continue_with_issue?(issue, issue_state_fetcher, Keyword.get(opts, :degraded_turns, 0))
  end

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.settings!().tracker.active_states
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp selected_worker_host(nil, []), do: nil

  defp selected_worker_host(preferred_host, configured_hosts) when is_list(configured_hosts) do
    hosts =
      configured_hosts
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case preferred_host do
      host when is_binary(host) and host != "" -> host
      _ when hosts == [] -> nil
      _ -> List.first(hosts)
    end
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
