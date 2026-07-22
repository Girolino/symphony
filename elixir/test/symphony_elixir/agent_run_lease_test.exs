defmodule SymphonyElixir.AgentRunLeaseTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentRunLease

  defmodule WorkpadRaceLinearClient do
    @spec graphql(String.t(), map(), keyword()) :: {:ok, map()}
    def graphql(query, variables, _opts) do
      if String.contains?(query, "commentCreate") do
        table = Application.fetch_env!(:symphony_elixir, :workpad_race_table)

        :ets.insert(table, {
          {:comment_create, System.unique_integer([:positive, :monotonic])},
          variables
        })

        {:ok, %{"data" => %{"commentCreate" => %{"success" => true}}}}
      else
        {:ok, %{"data" => %{}}}
      end
    end
  end

  test "lease acquisition returns busy while held and succeeds after release" do
    workspace_root = lease_workspace_root("basic")
    on_exit(fn -> File.rm_rf(workspace_root) end)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    issue = %Issue{id: "issue-lease-basic", identifier: "SYM-LEASE", title: "Lease", state: "In Progress"}

    assert {:ok, lease} = AgentRunLease.acquire(issue)
    assert :busy = AgentRunLease.acquire(issue)
    assert :ok = AgentRunLease.release(lease)
    assert {:ok, second_lease} = AgentRunLease.acquire(issue)
    assert :ok = AgentRunLease.release(second_lease)

    refute File.exists?(Path.join([workspace_root, ".symphony-run-locks", "issue-lease-basic"]))
  end

  test "lease release ignores non-owner tokens" do
    workspace_root = lease_workspace_root("release-token")
    on_exit(fn -> File.rm_rf(workspace_root) end)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    issue = %Issue{id: "issue-lease-token", identifier: "SYM-TOKEN", title: "Lease", state: "In Progress"}

    assert {:ok, lease} = AgentRunLease.acquire(issue, "worker-a")

    metadata =
      lease.path
      |> Path.join("owner.json")
      |> File.read!()
      |> Jason.decode!()

    assert metadata["worker_host"] == "worker-a"
    assert :ok = AgentRunLease.release(%{lease | token: "not-the-owner"})
    assert :busy = AgentRunLease.acquire(issue, "worker-a")

    assert :ok = AgentRunLease.release(lease)
  end

  test "lease acquisition reclaims a lock owned by a dead OS process" do
    workspace_root = lease_workspace_root("stale")
    on_exit(fn -> File.rm_rf(workspace_root) end)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    issue = %Issue{id: "issue-lease-stale", identifier: "SYM-STALE", title: "Lease", state: "In Progress"}
    lock_path = Path.join([workspace_root, ".symphony-run-locks", "issue-lease-stale"])

    write_dead_owner_lease!(lock_path, "old-token", issue)

    assert {:ok, lease} = AgentRunLease.acquire(issue)
    refute lease.token == "old-token"
    assert :ok = AgentRunLease.release(lease)
  end

  test "only one stale contender acquires after both observed the same stale lease" do
    workspace_root = lease_workspace_root("stale-race")
    on_exit(fn -> File.rm_rf(workspace_root) end)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    issue = %Issue{id: "issue-lease-stale-race", identifier: "SYM-STALE-RACE", title: "Lease", state: "In Progress"}
    lock_path = Path.join([workspace_root, ".symphony-run-locks", "issue-lease-stale-race"])
    write_dead_owner_lease!(lock_path, "old-token", issue)

    parent = self()

    Application.put_env(:symphony_elixir, :agent_run_lease_reclaim_observer, fn
      :stale_snapshot, %{path: ^lock_path} ->
        send(parent, {:stale_snapshot, Process.get(:lease_reclaim_label), self()})

        receive do
          :continue_reclaim -> :ok
        after
          2_000 -> raise "timed out waiting for stale reclaim race gate"
        end

      _event, _metadata ->
        :ok
    end)

    first =
      Task.async(fn ->
        Process.put(:lease_reclaim_label, :first)
        {:first, AgentRunLease.acquire(issue)}
      end)

    second =
      Task.async(fn ->
        Process.put(:lease_reclaim_label, :second)
        {:second, AgentRunLease.acquire(issue)}
      end)

    reclaimers =
      for _ <- 1..2 do
        receive do
          {:stale_snapshot, label, pid} -> {label, pid}
        after
          2_000 -> flunk("expected both contenders to observe the stale lease before reclaiming")
        end
      end

    {_first_label, first_pid} = Enum.find(reclaimers, fn {label, _pid} -> label == :first end)
    {_second_label, second_pid} = Enum.find(reclaimers, fn {label, _pid} -> label == :second end)

    send(first_pid, :continue_reclaim)
    assert {:first, {:ok, lease}} = Task.await(first, 2_000)

    send(second_pid, :continue_reclaim)
    assert {:second, :busy} = Task.await(second, 2_000)

    metadata =
      lease.path
      |> Path.join("owner.json")
      |> File.read!()
      |> Jason.decode!()

    assert metadata["token"] == lease.token
    assert :ok = AgentRunLease.release(lease)
  end

  test "stale reclaim returns busy while another contender holds the reclaim lock" do
    workspace_root = lease_workspace_root("stale-reclaim-held")
    on_exit(fn -> File.rm_rf(workspace_root) end)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    issue = %Issue{id: "issue-lease-held-reclaim", identifier: "SYM-HELD-RECLAIM", title: "Lease", state: "In Progress"}
    lock_path = Path.join([workspace_root, ".symphony-run-locks", "issue-lease-held-reclaim"])
    reclaim_path = "#{lock_path}.reclaiming"

    write_dead_owner_lease!(lock_path, "old-token", issue)
    File.mkdir_p!(reclaim_path)

    assert :busy = AgentRunLease.acquire(issue)

    metadata =
      lock_path
      |> Path.join("owner.json")
      |> File.read!()
      |> Jason.decode!()

    assert metadata["token"] == "old-token"
  end

  test "lease acquisition treats fresh missing metadata as busy" do
    workspace_root = lease_workspace_root("missing-metadata")
    on_exit(fn -> File.rm_rf(workspace_root) end)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    issue = %Issue{id: "issue-lease-missing", identifier: "SYM-MISSING", title: "Lease", state: "In Progress"}
    lock_path = Path.join([workspace_root, ".symphony-run-locks", "issue-lease-missing"])

    File.mkdir_p!(lock_path)

    assert :busy = AgentRunLease.acquire(issue)
  end

  test "string identifiers are sanitized for lease paths" do
    workspace_root = lease_workspace_root("string")
    on_exit(fn -> File.rm_rf(workspace_root) end)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    assert {:ok, lease} = AgentRunLease.acquire("SYM/LEASE")

    lock_path = Path.join([workspace_root, ".symphony-run-locks", "SYM_LEASE"])
    assert File.dir?(lock_path)

    assert :ok = AgentRunLease.release(lease)
    refute File.exists?(lock_path)
    assert :ok = AgentRunLease.release(:not_a_lease)
  end

  test "dot-only string identifiers stay inside the lease root" do
    workspace_root = lease_workspace_root("dot-string")
    on_exit(fn -> File.rm_rf(workspace_root) end)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    assert {:ok, lease} = AgentRunLease.acquire("..")

    lease_root = Path.expand(Path.join(workspace_root, ".symphony-run-locks"))
    lock_path = Path.join(lease_root, "__")

    assert lease.path == lock_path
    assert File.dir?(lock_path)
    assert String.starts_with?(Path.expand(lease.path), lease_root)
    refute Path.expand(lease.path) == Path.expand(workspace_root)

    assert :ok = AgentRunLease.release(lease)
  end

  test "malformed issues without ids get deterministic fallback lease keys" do
    workspace_root = lease_workspace_root("fallback-key")
    on_exit(fn -> File.rm_rf(workspace_root) end)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    assert {:ok, first_lease} = AgentRunLease.acquire(%{title: "First malformed issue"})
    assert {:ok, second_lease} = AgentRunLease.acquire(%{title: "Second malformed issue"})

    refute first_lease.path == second_lease.path
    assert first_lease.issue_key =~ ~r/^unknown-issue-/
    assert second_lease.issue_key =~ ~r/^unknown-issue-/

    assert :ok = AgentRunLease.release(first_lease)
    assert :ok = AgentRunLease.release(second_lease)
  end

  test "lease acquisition treats fresh corrupt metadata as busy" do
    workspace_root = lease_workspace_root("corrupt-metadata")
    on_exit(fn -> File.rm_rf(workspace_root) end)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    issue = %Issue{id: "issue-lease-corrupt", identifier: "SYM-CORRUPT", title: "Lease", state: "In Progress"}
    lock_path = Path.join([workspace_root, ".symphony-run-locks", "issue-lease-corrupt"])

    File.mkdir_p!(lock_path)
    File.write!(Path.join(lock_path, "owner.json"), "not json")

    assert :busy = AgentRunLease.acquire(issue)
  end

  test "lease acquisition reclaims old parseable metadata with unknown shape" do
    workspace_root = lease_workspace_root("unknown-metadata")
    on_exit(fn -> File.rm_rf(workspace_root) end)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    issue = %Issue{id: "issue-lease-unknown", identifier: "SYM-UNKNOWN", title: "Lease", state: "In Progress"}
    lock_path = Path.join([workspace_root, ".symphony-run-locks", "issue-lease-unknown"])

    File.mkdir_p!(lock_path)
    File.write!(Path.join(lock_path, "owner.json"), Jason.encode!(%{token: "old-token"}))
    :ok = :file.change_time(lock_path, {{2020, 1, 1}, {0, 0, 0}})

    assert {:ok, lease} = AgentRunLease.acquire(issue)
    refute lease.token == "old-token"
    assert :ok = AgentRunLease.release(lease)
  end

  test "concurrent runners for one issue only bootstrap one workpad comment" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-run-lease-#{System.unique_integer([:positive])}"
      )

    table = :ets.new(:workpad_race_comments, [:public])
    trace_file = Path.join(test_root, "codex.trace")
    release_file = Path.join(test_root, "release-first")
    codex_binary = Path.join(test_root, "fake-codex")
    workspace_root = Path.join(test_root, "workspaces")

    try do
      File.mkdir_p!(test_root)
      File.mkdir_p!(workspace_root)
      File.write!(codex_binary, fake_codex_workpad_bootstrap_script())
      File.chmod!(codex_binary, 0o755)

      Application.put_env(:symphony_elixir, :workpad_race_table, table)
      Application.put_env(:symphony_elixir, :linear_graphql_client, &WorkpadRaceLinearClient.graphql/3)

      System.put_env("SYMPHONY_WORKPAD_RACE_TRACE", trace_file)
      System.put_env("SYMPHONY_WORKPAD_RACE_RELEASE", release_file)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_read_timeout_ms: 1_000,
        codex_turn_timeout_ms: 5_000
      )

      issue = %Issue{
        id: "issue-workpad-race",
        identifier: "SYM-RACE",
        title: "Race workpad bootstrap",
        description: "Two sessions should not create duplicate workpads",
        state: "In Progress",
        url: "https://example.org/issues/SYM-RACE",
        labels: []
      }

      parent = self()
      state_fetcher = fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end

      first =
        Task.async(fn ->
          AgentRunner.run(issue, parent, issue_state_fetcher: state_fetcher)
        end)

      assert_receive {:codex_worker_update, "issue-workpad-race", %{event: :session_started}}, 2_000
      assert_receive {:codex_worker_update, "issue-workpad-race", %{event: :tool_call_completed}}, 2_000
      assert :busy = AgentRunLease.acquire(issue)

      second =
        Task.async(fn ->
          AgentRunner.run(issue, parent, issue_state_fetcher: state_fetcher)
        end)

      assert :ok = Task.await(second, 2_000)
      File.write!(release_file, "release")
      assert :ok = Task.await(first, 5_000)

      comment_creates =
        table
        |> :ets.tab2list()
        |> Enum.filter(fn {{kind, _id}, _variables} -> kind == :comment_create end)

      assert [
               {{:comment_create, _id},
                %{
                  "body" => "## Codex Workpad\n\nrace",
                  "issueId" => "issue-workpad-race"
                }}
             ] = comment_creates

      trace_lines = trace_file |> File.read!() |> String.split("\n", trim: true)
      assert length(Enum.filter(trace_lines, &String.starts_with?(&1, "RUN:"))) == 1
    after
      System.delete_env("SYMPHONY_WORKPAD_RACE_TRACE")
      System.delete_env("SYMPHONY_WORKPAD_RACE_RELEASE")
      :ets.delete(table)
      File.rm_rf(test_root)
    end
  end

  defp fake_codex_workpad_bootstrap_script do
    """
    #!/bin/sh
    trace_file="${SYMPHONY_WORKPAD_RACE_TRACE:-/tmp/symphony-workpad-race.trace}"
    release_file="${SYMPHONY_WORKPAD_RACE_RELEASE:-}"
    printf 'RUN:%s\\n' "$$" >> "$trace_file"
    count=0

    while IFS= read -r _line; do
      count=$((count + 1))

      case "$count" in
        1)
          printf '%s\\n' '{"id":1,"result":{}}'
          ;;
        2)
          ;;
        3)
          printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-race"}}}'
          ;;
        4)
          printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-race"}}}'
          printf '%s\\n' '{"id":102,"method":"item/tool/call","params":{"name":"linear_graphql","callId":"call-race","threadId":"thread-race","turnId":"turn-race","arguments":{"query":"mutation CreateWorkpad($issueId: String!, $body: String!) { commentCreate(input: {issueId: $issueId, body: $body}) { success } }","variables":{"issueId":"issue-workpad-race","body":"## Codex Workpad\\n\\nrace"}}}}'
          ;;
        5)
          if [ -n "$release_file" ]; then
            waited=0

            while [ ! -f "$release_file" ] && [ "$waited" -lt 100 ]; do
              sleep 0.05
              waited=$((waited + 1))
            done
          else
            sleep 1
          fi

          printf '%s\\n' '{"method":"turn/completed"}'
          exit 0
          ;;
        *)
          ;;
      esac
    done
    """
  end

  defp lease_workspace_root(name) do
    Path.join(
      System.tmp_dir!(),
      "symphony-elixir-agent-run-lease-#{name}-#{System.unique_integer([:positive])}"
    )
  end

  defp write_dead_owner_lease!(lock_path, old_token, issue) do
    File.mkdir_p!(lock_path)

    File.write!(
      Path.join(lock_path, "owner.json"),
      Jason.encode!(%{
        token: old_token,
        issue_key: issue.id,
        issue_id: issue.id,
        issue_identifier: issue.identifier,
        owner_os_pid: "999999999",
        acquired_unix_ms: System.system_time(:millisecond)
      })
    )
  end
end
