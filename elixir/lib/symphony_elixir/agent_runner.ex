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

  defp run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host) do
    max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)

    with {:ok, session} <- AppServer.start_session(workspace, worker_host: worker_host) do
      try do
        do_run_codex_turns(session, workspace, issue, codex_update_recipient, opts, issue_state_fetcher, 1, max_turns)
      after
        AppServer.stop_session(session)
      end
    end
  end

  defp do_run_codex_turns(app_session, workspace, issue, codex_update_recipient, opts, issue_state_fetcher, turn_number, max_turns) do
    prompt = build_turn_prompt(issue, opts, turn_number, max_turns)

    case AppServer.run_turn(
           app_session,
           prompt,
           issue,
           on_message: codex_message_handler(codex_update_recipient, issue)
         ) do
      {:ok, turn_session} ->
        Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{max_turns}")

        case continue_with_issue?(issue, issue_state_fetcher, Keyword.get(opts, :sleep_fun, &Process.sleep/1)) do
          {:continue, refreshed_issue} when turn_number < max_turns ->
            ctx = %{
              app_session: app_session,
              workspace: workspace,
              codex_update_recipient: codex_update_recipient,
              opts: opts,
              issue_state_fetcher: issue_state_fetcher,
              max_turns: max_turns
            }

            continue_or_end_at_role_boundary(ctx, issue, refreshed_issue, turn_number)

          {:continue, refreshed_issue} ->
            Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; returning control to orchestrator")

            :ok

          {:done, _refreshed_issue} ->
            :ok

          {:defer, reason} ->
            Logger.warning(
              "post-turn issue-state refresh failed for #{issue_context(issue)} session_id=#{turn_session[:session_id]}: #{inspect(reason)}; returning control to orchestrator continuation retry"
            )

            :ok
        end

      {:error, :response_timeout} when turn_number > 1 ->
        Logger.warning(
          "follow-up Codex turn start failed for #{issue_context(issue)} thread_id=#{app_session[:thread_id]} turn=#{turn_number}/#{max_turns}: :response_timeout; returning control to orchestrator continuation retry"
        )

        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp continue_or_end_at_role_boundary(ctx, issue, refreshed_issue, turn_number) do
    if role_boundary_crossed?(issue.state, refreshed_issue.state) do
      Logger.info("Ending session at role boundary for #{issue_context(refreshed_issue)}: #{inspect(issue.state)} -> #{inspect(refreshed_issue.state)}; a fresh session will own the new role")

      :ok
    else
      Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{ctx.max_turns}")

      do_run_codex_turns(
        ctx.app_session,
        ctx.workspace,
        refreshed_issue,
        ctx.codex_update_recipient,
        ctx.opts,
        ctx.issue_state_fetcher,
        turn_number + 1,
        ctx.max_turns
      )
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

  # SPEC 11.4: a running-state refresh failure must never kill an in-flight agent
  # run. A completed Codex turn is already-paid-for model spend; discarding it
  # because Linear rate-limited a read costs a full-context re-send on retry.
  # Retry the read a small bounded number of times, then degrade to the stale
  # snapshot and let the orchestrator poll loop reconcile terminal state.
  @refresh_max_attempts 3
  @refresh_base_backoff_ms 2_000
  @refresh_max_backoff_ms 8_000

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher, sleep_fun)
       when is_binary(issue_id) do
    refresh_issue_state(issue, issue_state_fetcher, sleep_fun, 1)
  end

  defp continue_with_issue?(issue, _issue_state_fetcher, _sleep_fun), do: {:done, issue}

  defp refresh_issue_state(%Issue{id: issue_id} = issue, issue_state_fetcher, sleep_fun, attempt) do
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

          attempt < @refresh_max_attempts ->
            delay = refresh_backoff_ms(attempt, reason)

            Logger.warning(
              "post-turn issue-state refresh attempt #{attempt}/#{@refresh_max_attempts} failed for #{issue_context(issue)}: #{inspect(reason)}; retrying in #{delay}ms"
            )

            sleep_fun.(delay)
            refresh_issue_state(issue, issue_state_fetcher, sleep_fun, attempt + 1)

          true ->
            Logger.warning(
              "post-turn issue-state refresh failed for #{issue_context(issue)} after #{@refresh_max_attempts} attempts: #{inspect(reason)}; continuing with the stale issue snapshot per SPEC 11.4 instead of failing the run"
            )

            {:continue, issue}
        end
    end
  end

  @doc false
  @spec refresh_backoff_ms(pos_integer(), term()) :: pos_integer()
  def refresh_backoff_ms(attempt, reason) when is_integer(attempt) and attempt >= 1 do
    case retry_after_ms(reason) do
      ms when is_integer(ms) and ms > 0 -> min(ms, @refresh_max_backoff_ms)
      _ -> min(@refresh_base_backoff_ms * Integer.pow(2, attempt - 1), @refresh_max_backoff_ms)
    end
  end

  defp retry_after_ms({:tracker_rate_limited, %{retry_after_ms: ms}}), do: ms
  defp retry_after_ms(_reason), do: nil

  @doc false
  @spec continue_with_issue_for_test(Issue.t(), (list() -> term()), keyword()) ::
          {:continue, Issue.t()} | {:done, Issue.t()} | {:defer, term()}
  def continue_with_issue_for_test(issue, issue_state_fetcher, opts \\ []) do
    continue_with_issue?(issue, issue_state_fetcher, Keyword.get(opts, :sleep_fun, &Process.sleep/1))
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
