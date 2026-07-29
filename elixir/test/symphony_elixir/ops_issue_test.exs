defmodule SymphonyElixir.OpsIssueTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.OpsIssue

  defp fake_graphql(scenario) do
    fn _endpoint, _api_key, query, variables ->
      cond do
        String.contains?(query, "SymphonyOpsFindIssue") -> find_issue_response(scenario)
        String.contains?(query, "SymphonyOpsTeam") -> team_response()
        String.contains?(query, "SymphonyOpsProject") -> project_response(scenario)
        String.contains?(query, "SymphonyOpsCreateIssue") -> create_issue_response(variables)
        true -> {:error, {:unexpected_query, query}}
      end
    end
  end

  defp find_issue_response(:existing) do
    {:ok,
     %{
       "data" => %{
         "issues" => %{"nodes" => [%{"id" => "iss-1", "identifier" => "SYME2E-7", "url" => "u"}]}
       }
     }}
  end

  defp find_issue_response(_scenario), do: {:ok, %{"data" => %{"issues" => %{"nodes" => []}}}}

  defp team_response do
    {:ok,
     %{
       "data" => %{
         "teams" => %{
           "nodes" => [
             %{
               "id" => "team-1",
               "key" => "SYME2E",
               "states" => %{
                 "nodes" => [
                   %{"id" => "st-backlog", "name" => "Backlog", "type" => "backlog"},
                   %{"id" => "st-todo", "name" => "Todo", "type" => "unstarted"}
                 ]
               }
             }
           ]
         }
       }
     }}
  end

  defp project_response(:project_missing), do: {:ok, %{"data" => %{"projects" => %{"nodes" => []}}}}

  defp project_response(_scenario) do
    {:ok, %{"data" => %{"projects" => %{"nodes" => [%{"id" => "proj-1", "slugId" => "slug-1"}]}}}}
  end

  defp create_issue_response(variables) do
    send(self(), {:create_variables, variables})

    {:ok,
     %{
       "data" => %{
         "issueCreate" => %{
           "success" => true,
           "issue" => %{"id" => "new-1", "identifier" => "SYME2E-42", "url" => "u2"}
         }
       }
     }}
  end

  # project_slug is pinned so ambient SYMPHONY_OPS_PROJECT_SLUG (set in real
  # promotion environments) can never change which branches these tests take.
  defp base_opts(scenario) do
    [
      graphql_fun: fake_graphql(scenario),
      get_env: fn "LINEAR_API_KEY" -> "test-key" end,
      team_key: "SYME2E",
      project_slug: nil
    ]
  end

  test "returns the existing open issue instead of duplicating" do
    assert {:existing, %{"identifier" => "SYME2E-7"}} =
             OpsIssue.file("promote FAIL: smoke failed", "body", base_opts(:existing))

    refute_received {:create_variables, _}
  end

  test "creates a new issue attached to the resolved project" do
    opts = Keyword.put(base_opts(:fresh), :project_slug, "slug-1")

    assert {:created, %{"identifier" => "SYME2E-42"}} =
             OpsIssue.file("promote FAIL: smoke failed", "body", opts)

    assert_received {:create_variables, %{projectId: "proj-1", teamId: "team-1", stateId: "st-todo"}}
  end

  test "a configured but unresolvable project fails loudly instead of team-only" do
    opts = Keyword.put(base_opts(:project_missing), :project_slug, "missing-slug")

    assert {:error, {:project_not_found, "missing-slug", _}} =
             OpsIssue.file("watchdog restart", "body", opts)

    refute_received {:create_variables, _}
  end

  test "propagates key-resolution failure by name only" do
    opts = [
      graphql_fun: fake_graphql(:fresh),
      get_env: fn "LINEAR_API_KEY" -> nil end,
      bootstrap_path: "/nonexistent/bootstrap"
    ]

    assert {:error, message} = OpsIssue.file("t", "b", opts)
    assert message =~ "LINEAR_API_KEY"
  end

  test "test runs fail closed instead of using the default live Linear transport" do
    opts = [
      get_env: fn "LINEAR_API_KEY" -> "live-looking-test-key" end,
      bootstrap_path: "/nonexistent/bootstrap"
    ]

    assert {:error, :test_live_linear_ops_issue_disabled} =
             OpsIssue.file("breaker parked: SYM-1", "body", opts)
  end

  test "creates team-only when no project slug is configured" do
    opts = Keyword.put(base_opts(:fresh), :project_slug, nil)

    assert {:created, _issue} = OpsIssue.file("gate FAIL", "body", opts)
    assert_received {:create_variables, %{projectId: nil}}
  end

  test "errors when the team cannot be resolved" do
    graphql = fn _e, _k, query, _v ->
      cond do
        String.contains?(query, "SymphonyOpsFindIssue") -> {:ok, %{"data" => %{"issues" => %{"nodes" => []}}}}
        String.contains?(query, "SymphonyOpsTeam") -> {:ok, %{"data" => %{"teams" => %{"nodes" => []}}}}
        true -> {:error, :unused}
      end
    end

    opts = [graphql_fun: graphql, get_env: fn "LINEAR_API_KEY" -> "k" end, team_key: "NOPE", project_slug: nil]
    assert {:error, {:team_not_found, "NOPE", _}} = OpsIssue.file("t", "b", opts)
  end

  test "propagates transport errors from team lookup and creation" do
    down = fn _e, _k, query, _v ->
      if String.contains?(query, "SymphonyOpsFindIssue"),
        do: {:ok, %{"data" => %{"issues" => %{"nodes" => []}}}},
        else: {:error, {:linear_api_request, :timeout}}
    end

    opts = [graphql_fun: down, get_env: fn "LINEAR_API_KEY" -> "k" end, project_slug: nil]
    assert {:error, {:linear_api_request, :timeout}} = OpsIssue.file("t", "b", opts)

    create_rejected = fn _e, _k, query, _v ->
      cond do
        String.contains?(query, "SymphonyOpsFindIssue") -> {:ok, %{"data" => %{"issues" => %{"nodes" => []}}}}
        String.contains?(query, "SymphonyOpsTeam") -> {:ok, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "t1", "key" => "K", "states" => %{"nodes" => []}}]}}}}
        String.contains?(query, "SymphonyOpsCreateIssue") -> {:ok, %{"data" => %{"issueCreate" => %{"success" => false}}}}
        true -> {:error, :unused}
      end
    end

    opts = [graphql_fun: create_rejected, get_env: fn "LINEAR_API_KEY" -> "k" end, project_slug: nil]
    assert {:error, {:issue_create_failed, _}} = OpsIssue.file("t", "b", opts)

    create_error = fn _e, _k, query, _v ->
      cond do
        String.contains?(query, "SymphonyOpsFindIssue") -> {:ok, %{"data" => %{"issues" => %{"nodes" => []}}}}
        String.contains?(query, "SymphonyOpsTeam") -> {:ok, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "t1", "key" => "K", "states" => %{"nodes" => []}}]}}}}
        String.contains?(query, "SymphonyOpsCreateIssue") -> {:error, {:linear_api_status, 500}}
        true -> {:error, :unused}
      end
    end

    opts = [graphql_fun: create_error, get_env: fn "LINEAR_API_KEY" -> "k" end, project_slug: nil]
    assert {:error, {:linear_api_status, 500}} = OpsIssue.file("t", "b", opts)
  end

  test "CR-001: a failed dedup lookup aborts filing instead of duplicating" do
    lookup_down = fn _e, _k, query, _v ->
      if String.contains?(query, "SymphonyOpsFindIssue") do
        {:error, :timeout}
      else
        send(self(), {:unexpected_call, query})
        {:error, :should_not_be_called}
      end
    end

    opts = [graphql_fun: lookup_down, get_env: fn "LINEAR_API_KEY" -> "k" end, project_slug: nil]
    assert {:error, {:dedup_lookup_failed, :timeout}} = OpsIssue.file("promote FAIL", "b", opts)
    refute_received {:unexpected_call, _}
  end

  test "CR-001: a malformed dedup lookup payload also aborts filing" do
    weird = fn _e, _k, query, _v ->
      if String.contains?(query, "SymphonyOpsFindIssue"),
        do: {:ok, %{"unexpected" => true}},
        else: {:error, :should_not_be_called}
    end

    opts = [graphql_fun: weird, get_env: fn "LINEAR_API_KEY" -> "k" end, project_slug: nil]
    assert {:error, {:dedup_lookup_failed, _}} = OpsIssue.file("t", "b", opts)
  end

  test "a project lookup transport error also aborts filing" do
    transport_down = fn _e, _k, query, _v ->
      cond do
        String.contains?(query, "SymphonyOpsFindIssue") -> {:ok, %{"data" => %{"issues" => %{"nodes" => []}}}}
        String.contains?(query, "SymphonyOpsTeam") -> {:ok, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "t1", "key" => "K", "states" => %{"nodes" => []}}]}}}}
        String.contains?(query, "SymphonyOpsProject") -> {:error, :timeout}
        true -> {:error, :unused}
      end
    end

    opts = [graphql_fun: transport_down, get_env: fn "LINEAR_API_KEY" -> "k" end, project_slug: "slug-1"]
    assert {:error, {:project_lookup_failed, :timeout}} = OpsIssue.file("t", "b", opts)
  end
end
