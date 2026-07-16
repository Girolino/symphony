defmodule SymphonyElixir.OrchestratorLivenessTest do
  use SymphonyElixir.TestSupport

  @moduledoc """
  Runtime injection proofs for the liveness invariant (contract proof 3):
  a stuck state resolves by its default action without waiting, and the
  breaker parks the issue (never the system) after consecutive failures.
  """

  defmodule FakeFiler do
    @spec file(String.t(), String.t(), keyword()) :: {:created, map()}
    def file(title, body, _opts) do
      send(:liveness_test_process, {:ops_issue_filed, title, body})
      {:created, %{"identifier" => "SYM-FAKE", "url" => "u"}}
    end
  end

  setup do
    Process.register(self(), :liveness_test_process)

    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    previous_filer = Application.get_env(:symphony_elixir, :ops_issue_filer)
    Application.put_env(:symphony_elixir, :ops_issue_filer, FakeFiler)

    test_root = Path.join(System.tmp_dir!(), "liveness-#{System.unique_integer([:positive])}")
    workflow_file = Path.join(test_root, "WORKFLOW.md")
    File.mkdir_p!(test_root)
    original_workflow_path = Workflow.workflow_file_path()

    File.write!(workflow_file, """
    ---
    tracker:
      kind: memory
    polling:
      interval_ms: 60000
    workspace:
      root: #{test_root}/workspaces
    agent:
      max_concurrent_agents: 1
      max_consecutive_failures: 3
      blocked_max_age_ms: 1000
    observability:
      enabled: false
    ---

    Liveness injection workflow.
    """)

    Workflow.set_workflow_file_path(workflow_file)

    if Process.whereis(SymphonyElixir.WorkflowStore) do
      SymphonyElixir.WorkflowStore.force_reload()
    end

    on_exit(fn ->
      restore_env_value(:memory_tracker_issues, previous_memory_issues)
      restore_env_value(:ops_issue_filer, previous_filer)
      Workflow.set_workflow_file_path(original_workflow_path)

      if Process.whereis(SymphonyElixir.WorkflowStore) do
        SymphonyElixir.WorkflowStore.force_reload()
      end

      File.rm_rf(test_root)
    end)

    %{test_root: test_root}
  end

  defp restore_env_value(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_env_value(key, value), do: Application.put_env(:symphony_elixir, key, value)

  # Poll orchestrator state until `fun` returns true, ticking each round.
  # Timing-based sleeps flake under load (the CI/auto-promote gate); this drives
  # the state machine deterministically regardless of machine speed.
  defp eventually(pid, fun, timeout_ms \\ 3_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_eventually(pid, fun, deadline)
  end

  defp do_eventually(pid, fun, deadline) do
    state = :sys.get_state(pid)

    cond do
      fun.(state) ->
        state

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("condition not reached; last state blocked=#{inspect(Map.keys(state.blocked))} parked=#{inspect(Map.keys(state.parked))} retry=#{inspect(Map.keys(state.retry_attempts))}")

      true ->
        send(pid, :tick)
        Process.sleep(25)
        do_eventually(pid, fun, deadline)
    end
  end

  defp start_orchestrator!(issues) do
    Application.put_env(:symphony_elixir, :memory_tracker_issues, issues)
    name = Module.concat(__MODULE__, :"Orchestrator#{System.unique_integer([:positive])}")
    {:ok, pid} = Orchestrator.start_link(name: name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    pid
  end

  test "an over-age blocked issue re-enters retry with its failure count carried" do
    issue_id = "liveness-blocked-1"

    issues = [
      %Issue{id: issue_id, identifier: "LIV-1", title: "t", state: "In Progress", labels: [], blocked_by: []},
      %Issue{id: "occupant-1", identifier: "LIV-OCCUPANT", title: "t", state: "In Progress", labels: [], blocked_by: []}
    ]

    pid = start_orchestrator!(issues)
    Process.sleep(50)

    stale_blocked = %{
      issue_id: issue_id,
      failures: 2,
      identifier: "LIV-1",
      issue: hd(issues),
      worker_host: nil,
      workspace_path: nil,
      session_id: nil,
      error: "input required",
      blocked_at: DateTime.add(DateTime.utc_now(), -3600, :second),
      last_codex_message: nil,
      last_codex_event: nil,
      last_codex_timestamp: nil
    }

    # Occupy the single agent slot so the expired issue cannot be immediately
    # re-dispatched; the intermediate retry state stays observable.
    occupant_pid = spawn(fn -> Process.sleep(:infinity) end)

    occupant = %{
      pid: occupant_pid,
      ref: nil,
      identifier: "LIV-OCCUPANT",
      issue: %Issue{id: "occupant-1", identifier: "LIV-OCCUPANT", title: "t", state: "In Progress", labels: [], blocked_by: []},
      started_at: DateTime.utc_now()
    }

    initial = :sys.get_state(pid)

    :sys.replace_state(pid, fn _ ->
      initial
      |> Map.put(:blocked, %{issue_id => stale_blocked})
      |> Map.put(:running, %{"occupant-1" => occupant})
      |> Map.put(:claimed, MapSet.new([issue_id, "occupant-1"]))
    end)

    state =
      eventually(pid, fn st ->
        not Map.has_key?(st.blocked, issue_id) and match?(%{failures: 3}, Map.get(st.retry_attempts, issue_id))
      end)

    refute Map.has_key?(state.blocked, issue_id), "stale blocked entry must not wait forever"
    assert %{failures: 3} = Map.get(state.retry_attempts, issue_id), "carried failures must advance"
  end

  test "the breaker parks after consecutive failures, files the ops issue, and unparks on terminal" do
    issue_id = "liveness-breaker-1"

    issue = %Issue{id: issue_id, identifier: "LIV-2", title: "t", state: "In Progress", labels: [], blocked_by: []}
    pid = start_orchestrator!([issue])
    Process.sleep(50)

    agent_pid = spawn(fn -> Process.sleep(:infinity) end)
    ref = Process.monitor(agent_pid)

    running_entry = %{
      pid: agent_pid,
      ref: ref,
      identifier: "LIV-2",
      issue: issue,
      started_at: DateTime.utc_now()
    }

    initial = :sys.get_state(pid)

    :sys.replace_state(pid, fn _ ->
      initial
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{issue_id => %{attempt: 3, failures: 3}})
    end)

    # Inject the failure signal the orchestrator would receive on agent crash.
    send(pid, {:DOWN, ref, :process, agent_pid, :killed})

    state = eventually(pid, fn st -> Map.has_key?(st.parked, issue_id) end)

    assert Map.has_key?(state.parked, issue_id), "breaker must park after max consecutive failures"
    refute Map.has_key?(state.retry_attempts, issue_id)
    assert MapSet.member?(state.claimed, issue_id), "parked issues stay claimed (not re-dispatched)"
    assert_receive {:ops_issue_filed, "breaker parked: LIV-2", _body}, 2_000

    # Terminal reconciliation releases the park (a human/lane resolved it).
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [%{hd([issue]) | state: "Done"}])
    state = eventually(pid, fn st -> not Map.has_key?(st.parked, issue_id) end)

    refute Map.has_key?(state.parked, issue_id), "terminal issues must unpark"
    refute MapSet.member?(state.claimed, issue_id)
  end
end
