defmodule SymphonyElixir.Codex.DynamicToolTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.DynamicTool

  setup do
    workspace_root =
      Path.join(System.tmp_dir!(), "symphony-elixir-dynamic-tool-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(workspace_root) end)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    {:ok, workspace_root: workspace_root}
  end

  test "tool_specs advertises the linear_graphql input contract" do
    assert [
             %{
               "description" => description,
               "inputSchema" => %{
                 "properties" => %{
                   "query" => _,
                   "variables" => _
                 },
                 "required" => ["query"],
                 "type" => "object"
               },
               "name" => "linear_graphql",
               "type" => "function"
             }
           ] = DynamicTool.tool_specs()

    assert description =~ "Linear"
  end

  test "unsupported tools return a failure payload with the supported tool list" do
    response = DynamicTool.execute("not_a_real_tool", %{})

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => ~s(Unsupported dynamic tool: "not_a_real_tool".),
               "supportedTools" => ["linear_graphql"]
             }
           }

    assert response["contentItems"] == [
             %{
               "type" => "inputText",
               "text" => response["output"]
             }
           ]
  end

  test "linear_graphql returns successful GraphQL responses as tool text" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{
          "query" => "query Viewer { viewer { id } }",
          "variables" => %{"includeTeams" => false}
        },
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_123"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{"includeTeams" => false}, []}

    assert response["success"] == true
    assert Jason.decode!(response["output"]) == %{"data" => %{"viewer" => %{"id" => "usr_123"}}}
    assert response["contentItems"] == [%{"type" => "inputText", "text" => response["output"]}]
  end

  test "linear_graphql accepts a raw GraphQL query string" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        "  query Viewer { viewer { id } }  ",
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_456"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{}, []}
    assert response["success"] == true
  end

  test "default linear_graphql client blocks test mutations without live e2e opt-in" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "mutation UpdateIssue { issueUpdate(id: \"x\") { success } }"}
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "Linear GraphQL tool execution failed.",
               "reason" => ":test_live_linear_mutation_disabled"
             }
           }
  end

  test "default linear_graphql client allows live e2e opt-in through loopback", %{workspace_root: workspace_root} do
    previous_live_e2e_flag = System.get_env("SYMPHONY_RUN_LIVE_E2E")

    on_exit(fn ->
      restore_env("SYMPHONY_RUN_LIVE_E2E", previous_live_e2e_flag)
    end)

    write_workflow_file!(
      Workflow.workflow_file_path(),
      tracker_endpoint: "http://127.0.0.1:1/graphql",
      workspace_root: workspace_root
    )

    System.put_env("SYMPHONY_RUN_LIVE_E2E", "1")

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "mutation UpdateIssue { issueUpdate(id: \"x\") { success } }"}
      )

    assert response["success"] == false

    assert %{
             "error" => %{
               "message" => "Linear GraphQL request failed before receiving a successful response.",
               "reason" => reason
             }
           } = Jason.decode!(response["output"])

    assert reason =~ "econnrefused"
  end

  test "linear_graphql ignores legacy operationName arguments" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }", "operationName" => "Viewer"},
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_789"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{}, []}
    assert response["success"] == true
  end

  test "linear_graphql passes multi-operation documents through unchanged" do
    test_pid = self()

    query = """
    query Viewer { viewer { id } }
    query Teams { teams { nodes { id } } }
    """

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => query},
        linear_client: fn forwarded_query, variables, opts ->
          send(test_pid, {:linear_client_called, forwarded_query, variables, opts})
          {:ok, %{"errors" => [%{"message" => "Must provide operation name if query contains multiple operations."}]}}
        end
      )

    assert_received {:linear_client_called, forwarded_query, %{}, []}
    assert forwarded_query == String.trim(query)
    assert response["success"] == false
  end

  test "linear_graphql workpad creates converge after stale lookup races" do
    table = :ets.new(:workpad_bootstrap_guard_race, [:public])

    client = workpad_linear_client(table)
    lookup_args = workpad_lookup_args()

    assert lookup_args
           |> execute_with_client(client)
           |> output()
           |> get_in(["data", "issue", "comments", "nodes"]) == []

    assert lookup_args
           |> execute_with_client(client)
           |> output()
           |> get_in(["data", "issue", "comments", "nodes"]) == []

    tasks =
      for index <- 1..2 do
        Task.async(fn ->
          create =
            workpad_create_args("## Codex Workpad\n\ncreated by #{index}")
            |> execute_with_client(client)
            |> output()

          id = get_in(create, ["data", "commentCreate", "comment", "id"])

          update =
            workpad_update_args(id, "## Codex Workpad\n\nupdated by #{index}")
            |> execute_with_client(client)
            |> output()

          {create, update}
        end)
      end

    results = Enum.map(tasks, &Task.await(&1, 5_000))

    assert Enum.map(results, fn {create, _update} -> get_in(create, ["data", "commentCreate", "comment", "id"]) end) ==
             ["workpad-1", "workpad-1"]

    assert count_workpad_calls(table, :comment_create) == 1
    assert count_workpad_calls(table, :comment_update) == 2
    assert active_workpad_ids(table) == ["workpad-1"]
  end

  test "linear_graphql inline workpad creates converge after newly filed lookup races" do
    table = :ets.new(:workpad_bootstrap_guard_inline_race, [:public])

    client = inline_workpad_linear_client(table)
    lookup_args = workpad_lookup_args()

    assert lookup_args
           |> execute_with_client(client)
           |> output()
           |> get_in(["data", "issue", "comments", "nodes"]) == []

    assert lookup_args
           |> execute_with_client(client)
           |> output()
           |> get_in(["data", "issue", "comments", "nodes"]) == []

    tasks =
      for index <- 1..2 do
        Task.async(fn ->
          create =
            "## Codex Workpad\n\ninline created by #{index}"
            |> inline_workpad_create_args()
            |> execute_with_client(client)
            |> output()

          id = get_in(create, ["data", "commentCreate", "comment", "id"])

          update =
            workpad_update_args(id, "## Codex Workpad\n\ninline updated by #{index}")
            |> execute_with_client(client)
            |> output()

          {create, update}
        end)
      end

    results = Enum.map(tasks, &Task.await(&1, 5_000))

    assert Enum.map(results, fn {create, _update} -> get_in(create, ["data", "commentCreate", "comment", "id"]) end) ==
             ["workpad-1", "workpad-1"]

    assert count_workpad_calls(table, :comment_create) == 1
    assert count_workpad_calls(table, :comment_update) == 2
    assert count_workpad_calls(table, :comment_lookup) >= 4
    assert active_workpad_ids(table) == ["workpad-1"]
  end

  test "linear_graphql workpad creates converge when Linear hides newly created comments" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workpad-hidden-create-#{System.unique_integer([:positive])}"
      )

    table = :ets.new(:workpad_bootstrap_guard_hidden_create, [:public])

    on_exit(fn ->
      File.rm_rf(workspace_root)
    end)

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    client = stale_comment_lookup_workpad_linear_client(table)
    lookup_args = workpad_lookup_args()

    assert lookup_args
           |> execute_with_client(client)
           |> output()
           |> get_in(["data", "issue", "comments", "nodes"]) == []

    assert lookup_args
           |> execute_with_client(client)
           |> output()
           |> get_in(["data", "issue", "comments", "nodes"]) == []

    results =
      1..2
      |> Enum.map(fn index ->
        Task.async(fn ->
          "## Codex Workpad\n\ncreated while hidden #{index}"
          |> workpad_create_args()
          |> execute_with_client(client)
          |> output()
        end)
      end)
      |> Enum.map(&Task.await(&1, 5_000))

    assert Enum.map(results, &get_in(&1, ["data", "commentCreate", "comment", "id"])) ==
             ["workpad-1", "workpad-1"]

    assert count_workpad_calls(table, :comment_create) == 1
    assert active_workpad_ids(table) == ["workpad-1"]
  end

  test "linear_graphql workpad creates converge after two kickoff sessions both start empty" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workpad-two-session-kickoff-#{System.unique_integer([:positive])}"
      )

    table = :ets.new(:workpad_bootstrap_guard_two_session_kickoff, [:public])

    on_exit(fn ->
      File.rm_rf(workspace_root)
    end)

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    insert_workpad_comment(table, "resolved-workpad", %{
      "body" => "## Codex Workpad\n\nresolved history",
      "createdAt" => "2026-08-04T12:00:00Z",
      "updatedAt" => "2026-08-04T12:00:00Z",
      "resolvedAt" => "2026-08-04T12:01:00Z"
    })

    client = delayed_visibility_workpad_linear_client(table)

    assert active_workpad_ids(table) == []

    tasks =
      for index <- 1..2 do
        Task.async(fn ->
          workpad_create_args("## Codex Workpad\n\nkickoff session #{index}")
          |> execute_with_client(client)
          |> output()
        end)
      end

    results = Enum.map(tasks, &Task.await(&1, 5_000))

    assert Enum.map(results, &get_in(&1, ["data", "commentCreate", "comment", "id"])) ==
             ["workpad-1", "workpad-1"]

    assert count_workpad_calls(table, :comment_create) == 1
    assert count_workpad_calls(table, :comment_resolve) == 0
    assert active_workpad_ids(table) == ["workpad-1"]

    assert table
           |> lookup_workpad_comment("resolved-workpad")
           |> Map.fetch!("resolvedAt")
  end

  test "linear_graphql cached workpad creates ignore directly resolved history" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workpad-resolved-cache-#{System.unique_integer([:positive])}"
      )

    table = :ets.new(:workpad_bootstrap_guard_resolved_cache, [:public])

    on_exit(fn ->
      File.rm_rf(workspace_root)
    end)

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    client = stale_comment_lookup_workpad_linear_client(table)

    first =
      "## Codex Workpad\n\nfirst cached"
      |> workpad_create_args()
      |> execute_with_client(client)
      |> output()

    assert get_in(first, ["data", "commentCreate", "comment", "id"]) == "workpad-1"
    assert {:ok, _response} = handle_workpad_resolve(table, %{"id" => "workpad-1"})

    second =
      "## Codex Workpad\n\nreplacement"
      |> workpad_create_args()
      |> execute_with_client(client)
      |> output()

    assert get_in(second, ["data", "commentCreate", "comment", "id"]) == "workpad-2"
    assert count_workpad_calls(table, :comment_create) == 2
    assert active_workpad_ids(table) == ["workpad-2"]
  end

  test "linear_graphql cached workpad creates ignore visibly resolved cache entries" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workpad-visible-resolved-cache-#{System.unique_integer([:positive])}"
      )

    issue_id = "issue-visible-resolved-cache"
    table = :ets.new(:workpad_bootstrap_guard_visible_resolved_cache, [:public])

    on_exit(fn ->
      File.rm_rf(workspace_root)
    end)

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    insert_workpad_comment(table, "cached-workpad", %{
      "body" => "## Codex Workpad\n\nresolved cached",
      "createdAt" => "2026-08-04T12:00:00Z",
      "updatedAt" => "2026-08-04T12:00:00Z",
      "resolvedAt" => "2026-08-04T12:01:00Z"
    })

    write_recent_workpad_cache!(workspace_root, issue_id, %{
      "id" => "cached-workpad",
      "body" => "## Codex Workpad\n\nresolved cached",
      "createdAt" => "2026-08-04T12:00:00Z",
      "updatedAt" => "2026-08-04T12:00:00Z"
    })

    create =
      "## Codex Workpad\n\nreplacement for visible resolved cache"
      |> workpad_create_args(issue_id)
      |> execute_with_client(workpad_linear_client(table))
      |> output()

    assert get_in(create, ["data", "commentCreate", "comment", "id"]) == "workpad-1"
    assert count_workpad_calls(table, :comment_create) == 1
    assert active_workpad_ids(table) == ["workpad-1"]
  end

  test "linear_graphql workpad create caches response when post-create lookup fails" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workpad-post-create-lookup-failure-#{System.unique_integer([:positive])}"
      )

    issue_id = "issue-post-create-lookup-failure"
    table = :ets.new(:workpad_bootstrap_guard_post_create_lookup_failure, [:public])
    lookup_counter = :counters.new(1, [])

    on_exit(fn ->
      File.rm_rf(workspace_root)
    end)

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    client = fn query, variables, opts ->
      cond do
        String.contains?(query, "comments") ->
          :counters.add(lookup_counter, 1, 1)

          case :counters.get(lookup_counter, 1) do
            1 -> {:ok, %{"data" => %{"issue" => %{"comments" => %{"nodes" => []}}}}}
            _sequence -> {:error, :post_create_lookup_failed}
          end

        String.contains?(query, "commentCreate") ->
          handle_workpad_create(table, variables)

        true ->
          workpad_linear_client(table).(query, variables, opts)
      end
    end

    create =
      "## Codex Workpad\n\ncreated despite post-create lookup failure"
      |> workpad_create_args(issue_id)
      |> execute_with_client(client)
      |> output()

    assert get_in(create, ["data", "commentCreate", "comment", "id"]) == "workpad-1"
    assert get_in(create, ["data", "commentCreate", "reusedExistingWorkpad"]) == false
    assert File.exists?(workpad_cache_path(workspace_root, issue_id))
  end

  test "linear_graphql workpad creates ignore stale recent cache files" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workpad-stale-cache-#{System.unique_integer([:positive])}"
      )

    issue_id = "issue-stale-cache"
    table = :ets.new(:workpad_bootstrap_guard_stale_cache, [:public])

    on_exit(fn ->
      File.rm_rf(workspace_root)
    end)

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    write_recent_workpad_cache!(
      workspace_root,
      issue_id,
      %{
        "id" => "cached-workpad",
        "body" => "## Codex Workpad\n\nstale cached",
        "createdAt" => "2026-08-04T12:00:00Z",
        "updatedAt" => "2026-08-04T12:00:00Z"
      },
      cached_unix_ms: 0
    )

    create =
      "## Codex Workpad\n\nfresh after stale cache"
      |> workpad_create_args(issue_id)
      |> execute_with_client(workpad_linear_client(table))
      |> output()

    assert get_in(create, ["data", "commentCreate", "comment", "id"]) == "workpad-1"
    assert count_workpad_calls(table, :comment_create) == 1
    assert active_workpad_ids(table) == ["workpad-1"]
  end

  test "linear_graphql workpad creates ignore missing cached comments after empty list reads" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workpad-missing-cache-comment-#{System.unique_integer([:positive])}"
      )

    issue_id = "issue-missing-cache-comment"
    table = :ets.new(:workpad_bootstrap_guard_missing_cache_comment, [:public])

    on_exit(fn ->
      File.rm_rf(workspace_root)
    end)

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    write_recent_workpad_cache!(workspace_root, issue_id, %{
      "id" => "missing-cached-workpad",
      "body" => "## Codex Workpad\n\nmissing cached",
      "createdAt" => "2026-08-04T12:00:00Z",
      "updatedAt" => "2026-08-04T12:00:00Z"
    })

    create =
      "## Codex Workpad\n\nfresh after missing cached comment"
      |> workpad_create_args(issue_id)
      |> execute_with_client(stale_comment_lookup_workpad_linear_client(table))
      |> output()

    assert get_in(create, ["data", "commentCreate", "comment", "id"]) == "workpad-1"
    assert count_workpad_calls(table, :comment_create) == 1
    assert active_workpad_ids(table) == ["workpad-1"]
  end

  test "linear_graphql workpad creates ignore visible resolved cache entries" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workpad-visible-resolved-cache-#{System.unique_integer([:positive])}"
      )

    on_exit(fn ->
      File.rm_rf(workspace_root)
    end)

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    resolved_table = :ets.new(:workpad_bootstrap_guard_unusable_resolved_cache, [:public])

    insert_workpad_comment(resolved_table, "resolved-cached-workpad", %{
      "body" => "## Codex Workpad\n\nresolved cached",
      "createdAt" => "2026-08-04T12:00:00Z",
      "updatedAt" => "2026-08-04T12:00:00Z",
      "resolvedAt" => "2026-08-04T12:01:00Z"
    })

    write_recent_workpad_cache!(workspace_root, "issue-visible-resolved-cache", %{
      "id" => "resolved-cached-workpad",
      "body" => "## Codex Workpad\n\nresolved cached",
      "createdAt" => "2026-08-04T12:00:00Z",
      "updatedAt" => "2026-08-04T12:00:00Z"
    })

    visible_resolved =
      "## Codex Workpad\n\nfresh after visible resolved cache"
      |> workpad_create_args("issue-visible-resolved-cache")
      |> execute_with_client(workpad_linear_client(resolved_table))
      |> output()

    assert get_in(visible_resolved, ["data", "commentCreate", "comment", "id"]) == "workpad-1"
    assert count_workpad_calls(resolved_table, :comment_create) == 1
  end

  test "linear_graphql workpad creates drop malformed cache timestamps" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workpad-malformed-cache-timestamp-#{System.unique_integer([:positive])}"
      )

    on_exit(fn ->
      File.rm_rf(workspace_root)
    end)

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    malformed_table = :ets.new(:workpad_bootstrap_guard_malformed_cache_timestamp, [:public])

    write_recent_workpad_cache!(
      workspace_root,
      "issue-malformed-cache-timestamp",
      %{
        "id" => "cached-workpad",
        "body" => "## Codex Workpad\n\nmalformed timestamp",
        "createdAt" => "2026-08-04T12:00:00Z",
        "updatedAt" => "2026-08-04T12:00:00Z"
      },
      cached_unix_ms: nil
    )

    malformed_timestamp =
      "## Codex Workpad\n\nfresh after malformed timestamp"
      |> workpad_create_args("issue-malformed-cache-timestamp")
      |> execute_with_client(stale_comment_lookup_workpad_linear_client(malformed_table))
      |> output()

    assert get_in(malformed_timestamp, ["data", "commentCreate", "comment", "id"]) == "workpad-1"
    assert count_workpad_calls(malformed_table, :comment_create) == 1
  end

  test "linear_graphql workpad creates drop invalid recent cache JSON" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workpad-invalid-cache-json-#{System.unique_integer([:positive])}"
      )

    issue_id = "issue-invalid-cache-json"
    table = :ets.new(:workpad_bootstrap_guard_invalid_cache_json, [:public])

    on_exit(fn ->
      File.rm_rf(workspace_root)
    end)

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    cache_path = workpad_cache_path(workspace_root, issue_id)
    File.mkdir_p!(Path.dirname(cache_path))
    File.write!(cache_path, "{invalid-json")

    create =
      "## Codex Workpad\n\nfresh after invalid cache json"
      |> workpad_create_args(issue_id)
      |> execute_with_client(stale_comment_lookup_workpad_linear_client(table))
      |> output()

    assert get_in(create, ["data", "commentCreate", "comment", "id"]) == "workpad-1"
    assert count_workpad_calls(table, :comment_create) == 1
    assert active_workpad_ids(table) == ["workpad-1"]
  end

  test "linear_graphql workpad creates drop malformed recent cache payloads" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workpad-malformed-cache-payload-#{System.unique_integer([:positive])}"
      )

    issue_id = "issue-malformed-cache-payload"
    table = :ets.new(:workpad_bootstrap_guard_malformed_cache_payload, [:public])

    on_exit(fn ->
      File.rm_rf(workspace_root)
    end)

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    cache_path = workpad_cache_path(workspace_root, issue_id)
    File.mkdir_p!(Path.dirname(cache_path))

    File.write!(
      cache_path,
      Jason.encode!(%{
        comment: nil,
        issue_id: issue_id,
        cached_unix_ms: System.system_time(:millisecond)
      })
    )

    create =
      "## Codex Workpad\n\nfresh after malformed cache payload"
      |> workpad_create_args(issue_id)
      |> execute_with_client(stale_comment_lookup_workpad_linear_client(table))
      |> output()

    assert get_in(create, ["data", "commentCreate", "comment", "id"]) == "workpad-1"
    assert count_workpad_calls(table, :comment_create) == 1
    assert active_workpad_ids(table) == ["workpad-1"]
  end

  test "linear_graphql workpad creates fail closed after cached-comment lookup errors" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workpad-cached-comment-error-#{System.unique_integer([:positive])}"
      )

    on_exit(fn ->
      File.rm_rf(workspace_root)
    end)

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    error_table = :ets.new(:workpad_bootstrap_guard_cached_comment_error, [:public])

    write_recent_workpad_cache!(workspace_root, "issue-cached-comment-error", %{
      "id" => "cached-workpad",
      "body" => "## Codex Workpad\n\ncomment error",
      "createdAt" => "2026-08-04T12:00:00Z",
      "updatedAt" => "2026-08-04T12:00:00Z"
    })

    lookup_error =
      "## Codex Workpad\n\nfresh after lookup error"
      |> workpad_create_args("issue-cached-comment-error")
      |> execute_with_client(cached_comment_error_workpad_linear_client(error_table))

    assert lookup_error["success"] == false

    assert get_in(Jason.decode!(lookup_error["output"]), ["error", "reason"]) ==
             "{:cached_workpad_comment_lookup_failed, \"cached-workpad\", :cached_comment_lookup_failed}"

    assert count_workpad_calls(error_table, :comment_create) == 0
    assert File.exists?(workpad_cache_path(workspace_root, "issue-cached-comment-error"))
  end

  test "linear_graphql workpad creates guard aliased input object variables" do
    table = :ets.new(:workpad_bootstrap_guard_aliased_input, [:public])

    client = workpad_linear_client(table)

    tasks =
      for index <- 1..2 do
        Task.async(fn ->
          "comment#{index}"
          |> workpad_create_args_with_variable("## Codex Workpad\n\ncreated by #{index}")
          |> execute_with_client(client)
          |> output()
        end)
      end

    results = Enum.map(tasks, &Task.await(&1, 5_000))

    assert Enum.map(results, &get_in(&1, ["data", "commentCreate", "comment", "id"])) ==
             ["workpad-1", "workpad-1"]

    assert count_workpad_calls(table, :comment_create) == 1
    assert active_workpad_ids(table) == ["workpad-1"]
  end

  test "linear_graphql workpad creates guard inline input object literals" do
    table = :ets.new(:workpad_bootstrap_guard_inline_input, [:public])

    query = ~S"""
    mutation CreateWorkpad {
      commentCreate(input: {issueId: "issue-workpad-race", body: "## Codex Workpad\n\ninline with ) and }"}) {
        success
        comment {
          id
          body
          resolvedAt
          createdAt
          updatedAt
        }
      }
    }
    """

    client = fn query, variables, opts ->
      cond do
        String.contains?(query, "commentCreate") ->
          handle_workpad_create(table, %{
            "body" => "## Codex Workpad\n\ninline",
            "issueId" => "issue-workpad-race"
          })

        String.contains?(query, "commentResolve") ->
          handle_workpad_resolve(table, variables)

        String.contains?(query, "comments") ->
          workpad_linear_client(table).(query, variables, opts)
      end
    end

    results =
      1..2
      |> Enum.map(fn _index ->
        Task.async(fn ->
          %{"query" => query}
          |> execute_with_client(client)
          |> output()
        end)
      end)
      |> Enum.map(&Task.await(&1, 5_000))

    assert Enum.map(results, &get_in(&1, ["data", "commentCreate", "comment", "id"])) ==
             ["workpad-1", "workpad-1"]

    assert count_workpad_calls(table, :comment_create) == 1
    assert active_workpad_ids(table) == ["workpad-1"]
  end

  test "linear_graphql inline workpad creates without issue id pass through unguarded" do
    test_pid = self()

    query = ~S"""
    mutation CreateWorkpad {
      commentCreate(input: {body: "## Codex Workpad\n\nmissing issue"}) {
        success
      }
    }
    """

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => query},
        linear_client: fn forwarded_query, variables, opts ->
          send(test_pid, {:unguarded_inline_create, forwarded_query, variables, opts})
          {:ok, %{"data" => %{"commentCreate" => %{"success" => true}}}}
        end
      )

    assert response["success"] == true
    assert_received {:unguarded_inline_create, _query, %{}, []}
  end

  test "linear_graphql workpad creates ignore resolved historical workpads" do
    table = :ets.new(:workpad_bootstrap_guard_resolved, [:public])

    insert_workpad_comment(table, "resolved-workpad", %{
      "body" => "## Codex Workpad\n\nold",
      "createdAt" => "2026-07-24T12:00:00Z",
      "updatedAt" => "2026-07-24T12:00:00Z",
      "resolvedAt" => "2026-07-24T12:01:00Z"
    })

    create =
      workpad_create_args("## Codex Workpad\n\nfresh")
      |> execute_with_client(workpad_linear_client(table))
      |> output()

    assert get_in(create, ["data", "commentCreate", "comment", "id"]) == "workpad-1"
    assert get_in(create, ["data", "commentCreate", "reusedExistingWorkpad"]) == false
    assert count_workpad_calls(table, :comment_create) == 1
    assert active_workpad_ids(table) == ["workpad-1"]
  end

  test "linear_graphql workpad creates resolve non-canonical active duplicates" do
    table = :ets.new(:workpad_bootstrap_guard_duplicates, [:public])

    insert_workpad_comment(table, "older-workpad", %{
      "body" => "## Codex Workpad\n\nolder",
      "createdAt" => "2026-07-24T12:00:00Z",
      "updatedAt" => "2026-07-24T12:00:00Z",
      "resolvedAt" => nil
    })

    insert_workpad_comment(table, "newer-workpad", %{
      "body" => "## Codex Workpad\n\nnewer",
      "createdAt" => "2026-07-24T12:00:10Z",
      "updatedAt" => "2026-07-24T12:00:10Z",
      "resolvedAt" => nil
    })

    insert_workpad_comment(table, "resolved-workpad", %{
      "body" => "## Codex Workpad\n\nresolved",
      "createdAt" => "2026-07-24T12:00:20Z",
      "updatedAt" => "2026-07-24T12:00:20Z",
      "resolvedAt" => "2026-07-24T12:00:30Z"
    })

    create =
      workpad_create_args("## Codex Workpad\n\nloser")
      |> execute_with_client(workpad_linear_client(table))
      |> output()

    assert get_in(create, ["data", "commentCreate", "comment", "id"]) == "newer-workpad"
    assert get_in(create, ["data", "commentCreate", "reusedExistingWorkpad"]) == true
    assert get_in(create, ["data", "commentCreate", "resolvedDuplicateIds"]) == ["older-workpad"]
    assert count_workpad_calls(table, :comment_create) == 0
    assert count_workpad_calls(table, :comment_resolve) == 1
    assert active_workpad_ids(table) == ["newer-workpad"]
  end

  test "linear_graphql workpad create preserves response when post-create duplicate resolution fails" do
    created = %{
      "body" => "## Codex Workpad\n\ncreated",
      "createdAt" => "2026-07-24T12:00:02Z",
      "id" => "created-workpad",
      "resolvedAt" => nil,
      "updatedAt" => "2026-07-24T12:00:02Z"
    }

    older = %{
      "body" => "## Codex Workpad\n\nolder",
      "createdAt" => "2026-07-24T12:00:01Z",
      "id" => "older-workpad",
      "resolvedAt" => nil,
      "updatedAt" => "2026-07-24T12:00:01Z"
    }

    comments_response = %{"data" => %{"issue" => %{"comments" => %{"nodes" => [older, created]}}}}
    lookup_counter = :counters.new(1, [])

    response =
      DynamicTool.execute(
        "linear_graphql",
        workpad_create_args("## Codex Workpad\n\ncreated"),
        linear_client: fn query, _variables, _opts ->
          cond do
            String.contains?(query, "comments(first: 50)") ->
              :counters.add(lookup_counter, 1, 1)

              case :counters.get(lookup_counter, 1) do
                1 -> {:ok, %{"data" => %{"issue" => %{"comments" => %{"nodes" => []}}}}}
                _ -> {:ok, comments_response}
              end

            String.contains?(query, "commentCreate") ->
              {:ok, %{"data" => %{"commentCreate" => %{"success" => true, "comment" => created}}}}

            String.contains?(query, "commentResolve") ->
              {:error, :resolve_after_create_failed}
          end
        end
      )

    assert response["success"] == true

    assert Jason.decode!(response["output"]) == %{
             "data" => %{"commentCreate" => %{"comment" => created, "success" => true}}
           }
  end

  test "linear_graphql workpad creates reclaim stale bootstrap locks" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workpad-stale-lock-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(workspace_root) end)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    lock_path =
      Path.join([
        Path.expand(workspace_root),
        ".symphony-workpad-bootstrap-locks",
        "issue-workpad-race"
      ])

    File.mkdir_p!(lock_path)
    File.write!(Path.join(lock_path, "owner.json"), "{}")
    :ok = :file.change_time(lock_path, {{2020, 1, 1}, {0, 0, 0}})

    table = :ets.new(:workpad_bootstrap_guard_stale_lock, [:public])

    create =
      workpad_create_args("## Codex Workpad\n\nfresh after stale lock")
      |> execute_with_client(workpad_linear_client(table))
      |> output()

    assert get_in(create, ["data", "commentCreate", "comment", "id"]) == "workpad-1"
    refute File.exists?(lock_path)
  end

  test "linear_graphql workpad lock metadata write failures release the created lock" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workpad-metadata-failure-#{System.unique_integer([:positive])}"
      )

    issue_id = "issue-workpad-metadata-failure"
    lock_path = workpad_lock_path(workspace_root, issue_id)

    on_exit(fn -> File.rm_rf(workspace_root) end)

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    Application.put_env(:symphony_elixir, :workpad_bootstrap_lock_metadata_writer, fn _path, _body ->
      {:error, :eacces}
    end)

    response =
      DynamicTool.execute(
        "linear_graphql",
        workpad_create_args("## Codex Workpad\n\nmetadata failure", issue_id),
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not run when lock metadata cannot be written")
        end
      )

    assert response["success"] == false
    assert response["output"] =~ "workpad_bootstrap_lock_metadata_failed"
    refute File.exists?(lock_path)

    raised_issue_id = "issue-workpad-metadata-raise"
    raised_lock_path = workpad_lock_path(workspace_root, raised_issue_id)

    Application.put_env(:symphony_elixir, :workpad_bootstrap_lock_metadata_writer, fn path, _body ->
      raise File.Error, reason: :eacces, action: "write to file", path: path
    end)

    raised_response =
      DynamicTool.execute(
        "linear_graphql",
        workpad_create_args("## Codex Workpad\n\nmetadata raise", raised_issue_id),
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not run when lock metadata writer raises")
        end
      )

    assert raised_response["success"] == false
    assert raised_response["output"] =~ "workpad_bootstrap_lock_metadata_failed"
    refute File.exists?(raised_lock_path)
  end

  test "linear_graphql workpad create reports lock directory create failures" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workpad-create-failure-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(workspace_root) end)

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    issue_id = String.duplicate("a", 300)

    response =
      DynamicTool.execute(
        "linear_graphql",
        workpad_create_args("## Codex Workpad\n\nlock create failure", issue_id),
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not run when lock directory creation fails")
        end
      )

    assert response["success"] == false
    assert response["output"] =~ "workpad_bootstrap_lock_create_failed"
  end

  test "linear_graphql workpad stale reclaim failures fail before calling Linear" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workpad-reclaim-failure-#{System.unique_integer([:positive])}"
      )

    issue_id = "issue-lock-reclaim-failure"
    lock_path = workpad_lock_path(workspace_root, issue_id)
    lock_parent = Path.dirname(lock_path)

    on_exit(fn ->
      File.chmod(lock_parent, 0o755)
      File.rm_rf(workspace_root)
    end)

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)
    File.mkdir_p!(lock_path)
    File.write!(Path.join(lock_path, "owner.json"), "{}")
    :ok = :file.change_time(lock_path, {{2020, 1, 1}, {0, 0, 0}})
    File.chmod!(lock_parent, 0o555)

    response =
      DynamicTool.execute(
        "linear_graphql",
        workpad_create_args("## Codex Workpad\n\nreclaim failure", issue_id),
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not run when stale lock reclaim fails")
        end
      )

    assert response["success"] == false
    assert response["output"] =~ "workpad_bootstrap_lock_reclaim_failed"
  end

  test "linear_graphql stale reclaim does not let an old holder remove a newer lock" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workpad-owned-lock-#{System.unique_integer([:positive])}"
      )

    issue_id = "issue-owned-lock"
    table = :ets.new(:workpad_bootstrap_guard_owned_lock, [:public])
    lock_path = workpad_lock_path(workspace_root, issue_id)

    on_exit(fn ->
      File.rm_rf(workspace_root)
    end)

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    client = blocking_workpad_linear_client(table, self())

    first =
      Task.async(fn ->
        "## Codex Workpad\n\nfirst"
        |> workpad_create_args(issue_id)
        |> execute_with_client(client)
      end)

    assert_receive {:blocking_comment_create_entered, first_pid}, 2_000
    assert File.exists?(lock_path)
    :ok = :file.change_time(lock_path, {{2020, 1, 1}, {0, 0, 0}})

    second =
      Task.async(fn ->
        "## Codex Workpad\n\nsecond"
        |> workpad_create_args(issue_id)
        |> execute_with_client(client)
      end)

    assert_receive {:blocking_comment_create_entered, second_pid}, 2_000
    refute first_pid == second_pid

    send(first_pid, :release_workpad_comment_create)
    assert first |> Task.await(5_000) |> output()
    assert File.exists?(lock_path)

    send(second_pid, :release_workpad_comment_create)
    assert second |> Task.await(5_000) |> output()

    refute File.exists?(lock_path)
    assert length(active_workpad_ids(table)) == 1
  end

  test "linear_graphql workpad release leaves lock in place when metadata disappears" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workpad-missing-metadata-#{System.unique_integer([:positive])}"
      )

    issue_id = "issue-missing-metadata"
    lock_path = workpad_lock_path(workspace_root, issue_id)

    on_exit(fn -> File.rm_rf(workspace_root) end)

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)
    table = :ets.new(:workpad_missing_metadata, [:public])

    response =
      DynamicTool.execute(
        "linear_graphql",
        workpad_create_args("## Codex Workpad\n\nmissing metadata", issue_id),
        linear_client: fn query, variables, opts ->
          if String.contains?(query, "commentCreate") do
            File.rm!(Path.join(lock_path, "owner.json"))
          end

          workpad_linear_client(table).(query, variables, opts)
        end
      )

    assert response["success"] == true
    assert File.exists?(lock_path)
  end

  test "linear_graphql workpad release leaves lock in place when metadata cannot be read" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workpad-unreadable-metadata-#{System.unique_integer([:positive])}"
      )

    issue_id = "issue-unreadable-metadata"
    lock_path = workpad_lock_path(workspace_root, issue_id)
    owner_path = Path.join(lock_path, "owner.json")

    on_exit(fn ->
      File.chmod(owner_path, 0o600)
      File.rm_rf(workspace_root)
    end)

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)
    table = :ets.new(:workpad_unreadable_metadata, [:public])

    response =
      DynamicTool.execute(
        "linear_graphql",
        workpad_create_args("## Codex Workpad\n\nunreadable metadata", issue_id),
        linear_client: fn query, variables, opts ->
          if String.contains?(query, "commentCreate") do
            File.chmod!(owner_path, 0o000)
          end

          workpad_linear_client(table).(query, variables, opts)
        end
      )

    assert response["success"] == true
    assert File.exists?(lock_path)
  end

  test "linear_graphql workpad creates without usable bootstrap inputs pass through unguarded" do
    test_pid = self()

    missing_issue =
      DynamicTool.execute(
        "linear_graphql",
        %{
          "query" => "mutation CreateWorkpad($input: CommentCreateInput!) { commentCreate(input: $input) { success } }",
          "variables" => %{"input" => %{"body" => "## Codex Workpad\n\nmissing issue"}}
        },
        linear_client: fn query, variables, opts ->
          send(test_pid, {:unguarded_create, query, variables, opts})
          {:ok, %{"data" => %{"commentCreate" => %{"success" => true}}}}
        end
      )

    assert missing_issue["success"] == true
    assert_received {:unguarded_create, _query, %{"input" => %{"body" => "## Codex Workpad\n\nmissing issue"}}, []}

    non_binary_body =
      DynamicTool.execute(
        "linear_graphql",
        %{
          "query" => "mutation CreateWorkpad($issueId: String!, $body: String!) { commentCreate(input: {issueId: $issueId, body: $body}) { success } }",
          "variables" => %{"body" => 42, "issueId" => "issue-workpad-race"}
        },
        linear_client: fn query, variables, opts ->
          send(test_pid, {:unguarded_create, query, variables, opts})
          {:ok, %{"data" => %{"commentCreate" => %{"success" => true}}}}
        end
      )

    assert non_binary_body["success"] == true
    assert_received {:unguarded_create, _query, %{"body" => 42, "issueId" => "issue-workpad-race"}, []}
  end

  test "linear_graphql workpad create fails closed when active lookup fails before create" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        workpad_create_args("## Codex Workpad\n\nblocked"),
        linear_client: fn query, _variables, _opts ->
          cond do
            String.contains?(query, "comments(first: 50)") -> {:error, :lookup_failed}
            String.contains?(query, "commentCreate") -> flunk("workpad create should not run after lookup failure")
          end
        end
      )

    assert response["success"] == false
    assert get_in(Jason.decode!(response["output"]), ["error", "reason"]) == ":lookup_failed"
  end

  test "linear_graphql workpad create preserves unsuccessful create responses" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        workpad_create_args("## Codex Workpad\n\ncreate failed"),
        linear_client: fn query, _variables, _opts ->
          cond do
            String.contains?(query, "comments(first: 50)") ->
              {:ok, %{"data" => %{"issue" => %{"comments" => %{"nodes" => []}}}}}

            String.contains?(query, "commentCreate") ->
              {:ok, %{"data" => %{"commentCreate" => %{"success" => false}}}}
          end
        end
      )

    assert response["success"] == true
    assert get_in(Jason.decode!(response["output"]), ["data", "commentCreate", "success"]) == false
  end

  test "linear_graphql workpad create handles duplicate resolve failures deterministically" do
    older = %{
      "body" => "## Codex Workpad\n\nolder",
      "createdAt" => "2026-07-24T12:00:00Z",
      "id" => "older-workpad",
      "resolvedAt" => nil,
      "updatedAt" => "2026-07-24T12:00:00Z"
    }

    newer = %{
      "body" => "## Codex Workpad\n\nnewer",
      "createdAt" => "2026-07-24T12:00:01Z",
      "id" => "newer-workpad",
      "resolvedAt" => nil,
      "updatedAt" => "2026-07-24T12:00:01Z"
    }

    response =
      DynamicTool.execute(
        "linear_graphql",
        workpad_create_args("## Codex Workpad\n\nloser"),
        linear_client: fn query, _variables, _opts ->
          cond do
            String.contains?(query, "comments(first: 50)") ->
              {:ok, %{"data" => %{"issue" => %{"comments" => %{"nodes" => [older, newer, "malformed"]}}}}}

            String.contains?(query, "commentResolve") ->
              {:error, :resolve_failed}

            String.contains?(query, "commentCreate") ->
              flunk("workpad create should not run when active workpads already exist")
          end
        end
      )

    assert response["success"] == false
    assert get_in(Jason.decode!(response["output"]), ["error", "reason"]) == ":resolve_failed"
  end

  test "linear_graphql rejects blank raw query strings even when using the default client" do
    response = DynamicTool.execute("linear_graphql", "   ")

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql` requires a non-empty `query` string."
             }
           }
  end

  test "linear_graphql marks GraphQL error responses as failures while preserving the body" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "mutation BadMutation { nope }"},
        linear_client: fn _query, _variables, _opts ->
          {:ok, %{"errors" => [%{"message" => "Unknown field `nope`"}], "data" => nil}}
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "data" => nil,
             "errors" => [%{"message" => "Unknown field `nope`"}]
           }
  end

  test "linear_graphql marks atom-key GraphQL error responses as failures" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts ->
          {:ok, %{errors: [%{message: "boom"}], data: nil}}
        end
      )

    assert response["success"] == false
  end

  test "linear_graphql validates required arguments before calling Linear" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"variables" => %{"commentId" => "comment-1"}},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when arguments are invalid")
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql` requires a non-empty `query` string."
             }
           }

    blank_query =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "   "},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when the query is blank")
        end
      )

    assert blank_query["success"] == false
  end

  test "linear_graphql rejects invalid argument types" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        [:not, :valid],
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when arguments are invalid")
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
             }
           }
  end

  test "linear_graphql rejects invalid variables" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }", "variables" => ["bad"]},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when variables are invalid")
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql.variables` must be a JSON object when provided."
             }
           }
  end

  test "linear_graphql formats transport and auth failures" do
    missing_token =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, :missing_linear_api_token} end
      )

    assert missing_token["success"] == false

    assert Jason.decode!(missing_token["output"]) == %{
             "error" => %{
               "message" => "Symphony is missing Linear auth. Set `linear.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
             }
           }

    status_error =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, {:linear_api_status, 503}} end
      )

    assert Jason.decode!(status_error["output"]) == %{
             "error" => %{
               "message" => "Linear GraphQL request failed with HTTP 503.",
               "status" => 503
             }
           }

    request_error =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, {:linear_api_request, :timeout}} end
      )

    assert Jason.decode!(request_error["output"]) == %{
             "error" => %{
               "message" => "Linear GraphQL request failed before receiving a successful response.",
               "reason" => ":timeout"
             }
           }
  end

  test "linear_graphql formats unexpected failures from the client" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, :boom} end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "Linear GraphQL tool execution failed.",
               "reason" => ":boom"
             }
           }
  end

  test "linear_graphql falls back to inspect for non-JSON payloads" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:ok, :ok} end
      )

    assert response["success"] == true
    assert response["output"] == ":ok"
  end

  defp execute_with_client(arguments, client) do
    DynamicTool.execute("linear_graphql", arguments, linear_client: client)
  end

  defp output(response) do
    assert response["success"] == true
    Jason.decode!(response["output"])
  end

  defp workpad_lookup_args do
    %{
      "query" => """
      query LookupWorkpads($issueId: String!) {
        issue(id: $issueId) {
          comments(first: 50) {
            nodes {
              id
              body
              resolvedAt
              createdAt
              updatedAt
            }
          }
        }
      }
      """,
      "variables" => %{"issueId" => "issue-workpad-race"}
    }
  end

  defp workpad_create_args(body, issue_id \\ "issue-workpad-race") do
    %{
      "query" => """
      mutation CreateWorkpad($input: CommentCreateInput!) {
        commentCreate(input: $input) {
          success
          comment {
            id
            body
            resolvedAt
            createdAt
            updatedAt
          }
        }
      }
      """,
      "variables" => %{"input" => %{"issueId" => issue_id, "body" => body}}
    }
  end

  defp workpad_create_args_with_variable(variable_name, body, issue_id \\ "issue-workpad-race") do
    %{
      "query" => """
      mutation CreateWorkpad($#{variable_name}: CommentCreateInput!) {
        commentCreate(input: $#{variable_name}) {
          success
          comment {
            id
            body
            resolvedAt
            createdAt
            updatedAt
          }
        }
      }
      """,
      "variables" => %{variable_name => %{"issueId" => issue_id, "body" => body}}
    }
  end

  defp inline_workpad_create_args(body, issue_id \\ "issue-workpad-race") do
    %{
      "query" => """
      mutation CreateWorkpad {
        commentCreate(input: {issueId: #{Jason.encode!(issue_id)}, body: #{Jason.encode!(body)}}) {
          success
          comment {
            id
            body
            resolvedAt
            createdAt
            updatedAt
          }
        }
      }
      """,
      "variables" => %{}
    }
  end

  defp workpad_update_args(id, body) do
    %{
      "query" => """
      mutation UpdateWorkpad($id: String!, $body: String!) {
        commentUpdate(id: $id, input: {body: $body}) {
          success
          comment {
            id
            body
          }
        }
      }
      """,
      "variables" => %{"id" => id, "body" => body}
    }
  end

  defp workpad_linear_client(table) do
    fn query, variables, _opts ->
      cond do
        String.contains?(query, "commentCreate") ->
          handle_workpad_create(table, variables)

        String.contains?(query, "commentUpdate") ->
          handle_workpad_update(table, variables)

        String.contains?(query, "commentResolve") ->
          handle_workpad_resolve(table, variables)

        String.contains?(query, "comment(id:") ->
          handle_workpad_comment_lookup(table, variables)

        String.contains?(query, "comments") ->
          record_workpad_call(table, :comment_lookup, variables)
          {:ok, %{"data" => %{"issue" => %{"comments" => %{"nodes" => workpad_comments(table)}}}}}

        true ->
          {:ok, %{"data" => %{}}}
      end
    end
  end

  defp handle_workpad_comment_lookup(table, variables) do
    record_workpad_call(table, :comment_lookup, variables)
    {:ok, %{"data" => %{"comment" => lookup_workpad_comment(table, Map.get(variables, "id"))}}}
  end

  defp inline_workpad_linear_client(table) do
    inline_variables = %{
      "input" => %{
        "body" => "## Codex Workpad\n\ninline",
        "issueId" => "issue-workpad-race"
      }
    }

    fn query, variables, opts ->
      if String.contains?(query, "commentCreate") and variables == %{} do
        handle_workpad_create(table, inline_variables)
      else
        workpad_linear_client(table).(query, variables, opts)
      end
    end
  end

  defp stale_comment_lookup_workpad_linear_client(table) do
    fn query, variables, opts ->
      if String.contains?(query, "comments") do
        record_workpad_call(table, :comment_lookup, variables)
        {:ok, %{"data" => %{"issue" => %{"comments" => %{"nodes" => []}}}}}
      else
        workpad_linear_client(table).(query, variables, opts)
      end
    end
  end

  defp cached_comment_error_workpad_linear_client(table) do
    fn query, variables, opts ->
      cond do
        String.contains?(query, "comment(id:") ->
          {:error, :cached_comment_lookup_failed}

        String.contains?(query, "comments") ->
          record_workpad_call(table, :comment_lookup, variables)
          {:ok, %{"data" => %{"issue" => %{"comments" => %{"nodes" => []}}}}}

        true ->
          workpad_linear_client(table).(query, variables, opts)
      end
    end
  end

  defp blocking_workpad_linear_client(table, test_pid) do
    fn query, variables, opts ->
      if String.contains?(query, "commentCreate") do
        send(test_pid, {:blocking_comment_create_entered, self()})

        receive do
          :release_workpad_comment_create ->
            handle_workpad_create(table, variables)
        after
          5_000 ->
            {:error, :workpad_comment_create_timeout}
        end
      else
        workpad_linear_client(table).(query, variables, opts)
      end
    end
  end

  defp delayed_visibility_workpad_linear_client(table) do
    fn query, variables, opts ->
      delayed_visibility_workpad_response(table, query, variables, opts)
    end
  end

  defp delayed_visibility_workpad_response(table, query, variables, opts) do
    cond do
      String.contains?(query, "commentCreate") -> handle_delayed_visibility_workpad_create(table, variables)
      String.contains?(query, "comments") -> handle_delayed_visibility_workpad_lookup(table, variables)
      true -> workpad_linear_client(table).(query, variables, opts)
    end
  end

  defp handle_delayed_visibility_workpad_create(table, variables) do
    with {:ok, response} <- handle_workpad_create(table, variables) do
      id = get_in(response, ["data", "commentCreate", "comment", "id"])
      :ets.insert(table, {{:created_by, self()}, id})
      {:ok, response}
    end
  end

  defp handle_delayed_visibility_workpad_lookup(table, variables) do
    record_workpad_call(table, :comment_lookup, variables)
    {:ok, %{"data" => %{"issue" => %{"comments" => %{"nodes" => visible_workpad_comments(table)}}}}}
  end

  defp handle_workpad_create(table, variables) do
    record_workpad_call(table, :comment_create, variables)
    sequence = :ets.update_counter(table, {:sequence, :comment}, {2, 1}, {{:sequence, :comment}, 0})
    id = "workpad-#{sequence}"

    comment = %{
      "id" => id,
      "body" => map_get_input(variables, "body"),
      "createdAt" => timestamp(sequence),
      "updatedAt" => timestamp(sequence),
      "resolvedAt" => nil,
      "url" => "https://linear.example/#{id}"
    }

    :ets.insert(table, {{:comment, id}, comment})

    {:ok, %{"data" => %{"commentCreate" => %{"success" => true, "comment" => comment}}}}
  end

  defp handle_workpad_update(table, variables) do
    record_workpad_call(table, :comment_update, variables)
    id = map_get_input(variables, "id")
    body = map_get_input(variables, "body")

    comment =
      table
      |> lookup_workpad_comment(id)
      |> Map.put("body", body)
      |> Map.put("updatedAt", timestamp(99))

    :ets.insert(table, {{:comment, id}, comment})

    {:ok, %{"data" => %{"commentUpdate" => %{"success" => true, "comment" => comment}}}}
  end

  defp handle_workpad_resolve(table, variables) do
    record_workpad_call(table, :comment_resolve, variables)
    id = map_get_input(variables, "id")

    case lookup_workpad_comment(table, id) do
      %{} = comment ->
        resolved = Map.put(comment, "resolvedAt", "2026-07-24T12:59:00Z")
        :ets.insert(table, {{:comment, id}, resolved})
        {:ok, %{"data" => %{"commentResolve" => %{"success" => true, "comment" => resolved}}}}

      nil ->
        {:ok, %{"data" => %{"commentResolve" => %{"success" => false}}}}
    end
  end

  defp insert_workpad_comment(table, id, attrs) do
    comment =
      Map.merge(
        %{
          "id" => id,
          "url" => "https://linear.example/#{id}"
        },
        attrs
      )

    :ets.insert(table, {{:comment, id}, comment})
  end

  defp workpad_comments(table) do
    table
    |> :ets.tab2list()
    |> Enum.flat_map(fn
      {{:comment, _id}, comment} -> [comment]
      _entry -> []
    end)
    |> Enum.sort_by(& &1["id"])
  end

  defp visible_workpad_comments(table) do
    case :ets.lookup(table, {:created_by, self()}) do
      [] ->
        historical_workpad_comments(table)

      [{_key, created_id}] ->
        sequence = :ets.update_counter(table, {:post_create_lookup, self()}, {2, 1}, {{:post_create_lookup, self()}, 0})

        if sequence == 1 do
          table
          |> historical_workpad_comments()
          |> Kernel.++([lookup_workpad_comment(table, created_id)])
          |> Enum.reject(&is_nil/1)
        else
          workpad_comments(table)
        end
    end
  end

  defp historical_workpad_comments(table) do
    table
    |> workpad_comments()
    |> Enum.filter(&Map.get(&1, "resolvedAt"))
  end

  defp active_workpad_ids(table) do
    table
    |> workpad_comments()
    |> Enum.filter(&(is_nil(&1["resolvedAt"]) and String.starts_with?(&1["body"], "## Codex Workpad")))
    |> Enum.map(& &1["id"])
    |> Enum.sort()
  end

  defp count_workpad_calls(table, kind) do
    table
    |> :ets.tab2list()
    |> Enum.count(fn
      {{:call, _sequence}, {^kind, _variables}} -> true
      _entry -> false
    end)
  end

  defp record_workpad_call(table, kind, variables) do
    sequence = :ets.update_counter(table, {:sequence, :call}, {2, 1}, {{:sequence, :call}, 0})
    :ets.insert(table, {{:call, sequence}, {kind, variables}})
  end

  defp lookup_workpad_comment(table, id) when is_binary(id) do
    case :ets.lookup(table, {:comment, id}) do
      [{_key, comment}] -> comment
      [] -> nil
    end
  end

  defp lookup_workpad_comment(_table, _id), do: nil

  defp workpad_lock_path(workspace_root, issue_id) do
    Path.join([
      Path.expand(workspace_root),
      ".symphony-workpad-bootstrap-locks",
      issue_id
    ])
  end

  defp workpad_cache_path(workspace_root, issue_id) do
    Path.join([
      Path.expand(workspace_root),
      ".symphony-workpad-bootstrap-cache",
      String.replace(issue_id, ~r/[^a-zA-Z0-9_-]/, "_") <> ".json"
    ])
  end

  defp write_recent_workpad_cache!(workspace_root, issue_id, comment, opts \\ []) do
    cache_path = workpad_cache_path(workspace_root, issue_id)
    File.mkdir_p!(Path.dirname(cache_path))

    payload = %{
      comment: comment,
      issue_id: issue_id,
      cached_unix_ms: Keyword.get(opts, :cached_unix_ms, System.system_time(:millisecond))
    }

    File.write!(cache_path, Jason.encode!(payload))
  end

  defp map_get_input(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) ->
        value

      _ ->
        find_nested_binary_value(map, key)
    end
  end

  defp find_nested_binary_value(map, key) when is_map(map) do
    Enum.find_value(map, fn
      {_nested_key, nested_map} when is_map(nested_map) ->
        Map.get(nested_map, key) || find_nested_binary_value(nested_map, key)

      _entry ->
        nil
    end)
  end

  defp find_nested_binary_value(_map, _key), do: nil

  defp timestamp(sequence) do
    "2026-07-24T12:00:#{String.pad_leading(to_string(sequence), 2, "0")}Z"
  end
end
