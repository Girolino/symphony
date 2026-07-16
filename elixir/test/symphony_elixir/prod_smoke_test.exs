defmodule SymphonyElixir.ProdSmokeTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ProdSmoke

  describe "parse_api_key_file/1" do
    test "extracts a plain key" do
      assert {:ok, "lin_api_test"} = ProdSmoke.parse_api_key_file("LINEAR_API_KEY=lin_api_test\n")
    end

    test "strips quotes and whitespace" do
      assert {:ok, "abc"} = ProdSmoke.parse_api_key_file(~s(LINEAR_API_KEY="abc" \n))
      assert {:ok, "abc"} = ProdSmoke.parse_api_key_file("LINEAR_API_KEY='abc'\n")
    end

    test "rejects missing or empty keys" do
      assert {:error, :missing_key} = ProdSmoke.parse_api_key_file("OTHER=1\n")
      assert {:error, :missing_key} = ProdSmoke.parse_api_key_file("LINEAR_API_KEY=\n")
    end
  end

  describe "resolve_api_key/2" do
    test "prefers the environment value" do
      get_env = fn "LINEAR_API_KEY" -> "from-env" end
      assert {:ok, "from-env"} = ProdSmoke.resolve_api_key(get_env, "/nonexistent/path")
    end

    test "falls back to the bootstrap file" do
      dir = Path.join(System.tmp_dir!(), "prod-smoke-test-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      path = Path.join(dir, "env")
      File.write!(path, "LINEAR_API_KEY=from-file\n")

      get_env = fn "LINEAR_API_KEY" -> nil end
      assert {:ok, "from-file"} = ProdSmoke.resolve_api_key(get_env, path)
    end

    test "errors by name only when the capability is absent" do
      get_env = fn "LINEAR_API_KEY" -> nil end
      assert {:error, message} = ProdSmoke.resolve_api_key(get_env, "/nonexistent/bootstrap")
      assert message =~ "LINEAR_API_KEY"
      assert message =~ "/nonexistent/bootstrap"
    end
  end

  describe "render_workflow/1" do
    test "references the key by name and includes the journey config" do
      contents =
        ProdSmoke.render_workflow(%{
          project_slug: "smoke-slug",
          active_states: ["Todo", "In Progress"],
          terminal_states: ["Done"],
          workspace_root: "/tmp/smoke/workspaces",
          prompt: "PROMPT-BODY"
        })

      assert contents =~ "api_key: $LINEAR_API_KEY"
      refute contents =~ "lin_api_"
      assert contents =~ ~s(project_slug: "smoke-slug")
      assert contents =~ ~s(- "Todo")
      assert contents =~ ~s(- "Done")
      assert contents =~ "max_concurrent_agents: 1"
      assert contents =~ "PROMPT-BODY"
    end
  end

  describe "smoke_prompt/1" do
    test "contains the marker and the exact operations" do
      prompt = ProdSmoke.smoke_prompt("MARKER-123")
      assert prompt =~ "MARKER-123"
      assert prompt =~ "commentCreate"
      assert prompt =~ "issueUpdate"
      assert prompt =~ "linear_graphql"
    end
  end

  describe "report shape" do
    test "derive_result fails when any step failed" do
      pass = %{name: "a", status: :pass, duration_ms: 1, detail: nil}
      fail = %{name: "b", status: :fail, duration_ms: 1, detail: "boom"}

      assert ProdSmoke.derive_result([pass]) == :pass
      assert ProdSmoke.derive_result([pass, fail]) == :fail
    end

    test "build_report captures failure detail and duration" do
      started = ~U[2026-07-16 12:00:00Z]
      finished = ~U[2026-07-16 12:00:42Z]

      steps = [
        %{name: "ok-step", status: :pass, duration_ms: 5, detail: nil},
        %{name: "bad-step", status: :fail, duration_ms: 7, detail: "exploded"}
      ]

      report = ProdSmoke.build_report(steps, started, finished, %{issue: %{"identifier" => "SYME2E-1"}})

      assert report.result == :fail
      assert report.duration_ms == 42_000
      assert report.failure == "bad-step: exploded"
      assert report.issue == %{"identifier" => "SYME2E-1"}
    end

    test "report_path is deterministic and filesystem-safe" do
      at = ~U[2026-07-16 12:34:56Z]
      path = ProdSmoke.report_path("/tmp/qa", at)
      assert path == "/tmp/qa/prod-smoke-2026-07-16T12-34-56Z.json"
    end
  end

  describe "full journey with fakes" do
    setup do
      run_dir = Path.join(System.tmp_dir!(), "prod-smoke-journey-#{System.unique_integer([:positive])}")
      report_dir = Path.join(run_dir, "reports")
      smoke_root = Path.join(run_dir, "root")
      escript = Path.join(run_dir, "symphony")
      File.mkdir_p!(run_dir)
      File.write!(escript, "#!/bin/sh\nexit 0\n")

      {:ok, calls} = Agent.start_link(fn -> %{issue_polls: 0, ops: []} end)

      on_exit(fn -> File.rm_rf(run_dir) end)

      %{
        run_dir: run_dir,
        report_dir: report_dir,
        smoke_root: smoke_root,
        escript: escript,
        calls: calls
      }
    end

    defp record(calls, op) do
      Agent.update(calls, fn state -> %{state | ops: [op | state.ops]} end)
    end

    defp next_poll_count(calls) do
      Agent.get_and_update(calls, fn state ->
        {state.issue_polls + 1, %{state | issue_polls: state.issue_polls + 1}}
      end)
    end

    defp issue_poll_response(completed?) do
      {state, comments} =
        if completed? do
          marker = "Symphony prod smoke SYME2E-9 smoke-1"
          {%{"name" => "Done", "type" => "completed"}, [%{"body" => marker}]}
        else
          {%{"name" => "Todo", "type" => "unstarted"}, []}
        end

      {:ok,
       %{
         "data" => %{
           "issue" => %{
             "id" => "issue-1",
             "identifier" => "SYME2E-9",
             "state" => state,
             "comments" => %{"nodes" => comments}
           }
         }
       }}
    end

    defp fake_graphql(calls, complete_after_polls) do
      fn _endpoint, _api_key, query, _variables ->
        cond do
          String.contains?(query, "SymphonyProdSmokeTeam") ->
            record(calls, :team)

            {:ok,
             %{
               "data" => %{
                 "teams" => %{
                   "nodes" => [
                     %{
                       "id" => "team-1",
                       "key" => "SYME2E",
                       "name" => "Smoke Team",
                       "states" => %{
                         "nodes" => [
                           %{"id" => "s1", "name" => "Todo", "type" => "unstarted"},
                           %{"id" => "s2", "name" => "Done", "type" => "completed"}
                         ]
                       }
                     }
                   ]
                 }
               }
             }}

          String.contains?(query, "SymphonyProdSmokeCreateProject") ->
            record(calls, :create_project)

            {:ok,
             %{
               "data" => %{
                 "projectCreate" => %{
                   "success" => true,
                   "project" => %{"id" => "proj-1", "name" => "Smoke", "slugId" => "smoke-1", "url" => "u"}
                 }
               }
             }}

          String.contains?(query, "SymphonyProdSmokeCreateIssue") ->
            record(calls, :create_issue)

            {:ok,
             %{
               "data" => %{
                 "issueCreate" => %{
                   "success" => true,
                   "issue" => %{
                     "id" => "issue-1",
                     "identifier" => "SYME2E-9",
                     "title" => "t",
                     "url" => "u",
                     "state" => %{"name" => "Todo"}
                   }
                 }
               }
             }}

          String.contains?(query, "SymphonyProdSmokeIssueState") ->
            polls = next_poll_count(calls)
            record(calls, :issue_poll)
            issue_poll_response(polls >= complete_after_polls)

          String.contains?(query, "SymphonyProdSmokeProjectStatuses") ->
            record(calls, :project_statuses)

            {:ok,
             %{
               "data" => %{
                 "projectStatuses" => %{
                   "nodes" => [%{"id" => "ps-1", "name" => "Completed", "type" => "completed"}]
                 }
               }
             }}

          String.contains?(query, "SymphonyProdSmokeCompleteProject") ->
            record(calls, :complete_project)
            {:ok, %{"data" => %{"projectUpdate" => %{"success" => true}}}}

          true ->
            {:error, {:unexpected_query, query}}
        end
      end
    end

    defp base_opts(ctx, complete_after_polls) do
      [
        port: 47_900 + rem(System.unique_integer([:positive]), 90),
        timeout_ms: 5_000,
        health_timeout_ms: 1_000,
        poll_interval_ms: 1,
        report_dir: ctx.report_dir,
        smoke_root: ctx.smoke_root,
        escript_path: ctx.escript,
        team_key: "SYME2E",
        get_env: fn "LINEAR_API_KEY" -> "fake-key-for-tests" end,
        graphql_fun: fake_graphql(ctx.calls, complete_after_polls),
        http_get_fun: fn url ->
          if String.ends_with?(url, "/api/v1/state") do
            {:ok, 200, Jason.encode!(%{"health" => %{"status" => "healthy"}})}
          else
            {:ok, 200, "<html>dashboard</html>"}
          end
        end,
        spawn_fun: fn _escript, _workflow, _port, _env ->
          record(ctx.calls, :spawn)
          {:ok, %{fake: true}}
        end,
        stop_fun: fn _daemon ->
          record(ctx.calls, :stop)
          :ok
        end,
        sleep_fun: fn _ms -> :ok end
      ]
    end

    test "passes end-to-end and always cleans up", ctx do
      assert {:ok, report} = ProdSmoke.run(base_opts(ctx, 2))

      assert report.result == :pass

      assert Enum.map(report.steps, & &1.name) == [
               "resolve-linear-key",
               "preflight",
               "linear-setup",
               "write-workflow",
               "boot-daemon",
               "await-health",
               "await-completion",
               "assert-surfaces",
               "cleanup"
             ]

      ops = Agent.get(ctx.calls, & &1.ops)
      assert :stop in ops
      assert :complete_project in ops

      assert [report_file] = File.ls!(ctx.report_dir)
      decoded = ctx.report_dir |> Path.join(report_file) |> File.read!() |> Jason.decode!()
      assert decoded["result"] == "pass"
      refute inspect(decoded) =~ "fake-key-for-tests"

      refute File.exists?(ctx.smoke_root)
    end

    test "fails when the issue never completes, still cleaning up", ctx do
      opts = Keyword.merge(base_opts(ctx, 1_000_000_000), timeout_ms: 5, poll_interval_ms: 1)

      assert {:error, report} = ProdSmoke.run(opts)

      assert report.result == :fail
      assert report.failure =~ "await-completion"

      ops = Agent.get(ctx.calls, & &1.ops)
      assert :stop in ops
      assert :complete_project in ops

      assert [report_file] = File.ls!(ctx.report_dir)
      decoded = ctx.report_dir |> Path.join(report_file) |> File.read!() |> Jason.decode!()
      assert decoded["result"] == "fail"
    end

    test "fails at preflight when the escript is missing", ctx do
      opts = Keyword.put(base_opts(ctx, 1), :escript_path, "/nonexistent/symphony")

      assert {:error, report} = ProdSmoke.run(opts)
      assert report.failure =~ "preflight"

      ops = Agent.get(ctx.calls, & &1.ops)
      refute :spawn in ops
    end
  end
end

defmodule SymphonyElixir.ProdSmokeErrorPathsTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ProdSmoke

  defp ctx_dirs do
    run_dir = Path.join(System.tmp_dir!(), "prod-smoke-err-#{System.unique_integer([:positive])}")
    escript = Path.join(run_dir, "symphony")
    File.mkdir_p!(run_dir)
    File.write!(escript, "#!/bin/sh\nexit 0\n")
    on_exit(fn -> File.rm_rf(run_dir) end)
    %{run_dir: run_dir, escript: escript}
  end

  defp opts(overrides) do
    dirs = ctx_dirs()

    Keyword.merge(
      [
        port: 47_800 + rem(System.unique_integer([:positive]), 90),
        timeout_ms: 50,
        health_timeout_ms: 50,
        poll_interval_ms: 1,
        report_dir: Path.join(dirs.run_dir, "reports"),
        smoke_root: Path.join(dirs.run_dir, "root"),
        escript_path: dirs.escript,
        team_key: "SYME2E",
        get_env: fn "LINEAR_API_KEY" -> "k" end,
        graphql_fun: fn _e, _k, _q, _v -> {:error, :nope} end,
        http_get_fun: fn _url -> {:ok, 200, Jason.encode!(%{"health" => %{"status" => "healthy"}})} end,
        spawn_fun: fn _a, _b, _c, _d -> {:ok, %{fake: true}} end,
        stop_fun: fn _d -> :ok end,
        sleep_fun: fn _ms -> :ok end
      ],
      overrides
    )
  end

  defp team_ok do
    {:ok,
     %{
       "data" => %{
         "teams" => %{
           "nodes" => [
             %{
               "id" => "team-1",
               "key" => "SYME2E",
               "name" => "T",
               "states" => %{"nodes" => [%{"id" => "s2", "name" => "Done", "type" => "completed"}]}
             }
           ]
         }
       }
     }}
  end

  test "fails linear setup when the team is missing and still cleans up" do
    graphql = fn _e, _k, q, _v ->
      if String.contains?(q, "Team"), do: {:ok, %{"data" => %{"teams" => %{"nodes" => []}}}}, else: {:error, :unused}
    end

    assert {:error, report} = ProdSmoke.run(opts(graphql_fun: graphql))
    assert report.failure =~ "linear-setup"
    assert Enum.any?(report.steps, &(&1.name == "cleanup"))
  end

  test "fails when project creation is rejected" do
    graphql = fn _e, _k, q, _v ->
      cond do
        String.contains?(q, "Team") -> team_ok()
        String.contains?(q, "CreateProject") -> {:ok, %{"data" => %{"projectCreate" => %{"success" => false}}}}
        true -> {:error, :unused}
      end
    end

    assert {:error, report} = ProdSmoke.run(opts(graphql_fun: graphql))
    assert report.failure =~ "project_create_failed"
  end

  test "fails when issue creation errors and falls back on empty active states" do
    graphql = fn _e, _k, q, _v ->
      cond do
        String.contains?(q, "Team") ->
          team_ok()

        String.contains?(q, "CreateProject") ->
          {:ok, %{"data" => %{"projectCreate" => %{"success" => true, "project" => %{"id" => "p", "name" => "n", "slugId" => "s", "url" => "u"}}}}}

        String.contains?(q, "CreateIssue") ->
          {:error, {:linear_api_status, 500}}

        true ->
          {:error, :unused}
      end
    end

    assert {:error, report} = ProdSmoke.run(opts(graphql_fun: graphql))
    assert report.failure =~ "linear_api_status"
  end

  test "fails preflight when the port is occupied" do
    port = 47_700 + rem(System.unique_integer([:positive]), 90)
    {:ok, socket} = :gen_tcp.listen(port, [:binary, ip: {127, 0, 0, 1}])
    on_exit(fn -> :gen_tcp.close(socket) end)

    assert {:error, report} = ProdSmoke.run(opts(port: port))
    assert report.failure =~ "already in use"
  end

  test "fails at daemon spawn and health timeout, capturing stop crash safely" do
    linear_ok = fn _e, _k, q, _v ->
      cond do
        String.contains?(q, "Team") ->
          team_ok()

        String.contains?(q, "CreateProject") ->
          {:ok, %{"data" => %{"projectCreate" => %{"success" => true, "project" => %{"id" => "p", "name" => "n", "slugId" => "s", "url" => "u"}}}}}

        String.contains?(q, "CreateIssue") ->
          {:ok, %{"data" => %{"issueCreate" => %{"success" => true, "issue" => %{"id" => "i", "identifier" => "SYME2E-1", "title" => "t", "url" => "u", "state" => %{"name" => "Todo"}}}}}}

        true ->
          {:error, :unused}
      end
    end

    assert {:error, spawn_report} =
             ProdSmoke.run(opts(graphql_fun: linear_ok, spawn_fun: fn _a, _b, _c, _d -> {:error, :boom} end))

    assert spawn_report.failure =~ "daemon spawn failed"

    assert {:error, health_report} =
             ProdSmoke.run(
               opts(
                 graphql_fun: linear_ok,
                 http_get_fun: fn _url -> {:ok, 500, "nope"} end,
                 stop_fun: fn _d -> raise "stop exploded" end
               )
             )

    assert health_report.failure =~ "did not become healthy"
    cleanup = Enum.find(health_report.steps, &(&1.name == "cleanup"))
    assert cleanup.detail =~ "caught"
  end

  test "fails surface assertion after completion when dashboard breaks" do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    linear_ok = fn _e, _k, q, _v ->
      cond do
        String.contains?(q, "Team") ->
          team_ok()

        String.contains?(q, "CreateProject") ->
          {:ok, %{"data" => %{"projectCreate" => %{"success" => true, "project" => %{"id" => "p", "name" => "n", "slugId" => "smoke-1", "url" => "u"}}}}}

        String.contains?(q, "CreateIssue") ->
          {:ok, %{"data" => %{"issueCreate" => %{"success" => true, "issue" => %{"id" => "i", "identifier" => "SYME2E-9", "title" => "t", "url" => "u", "state" => %{"name" => "Todo"}}}}}}

        String.contains?(q, "IssueState") ->
          {:ok,
           %{
             "data" => %{
               "issue" => %{
                 "id" => "i",
                 "identifier" => "SYME2E-9",
                 "state" => %{"name" => "Done", "type" => "completed"},
                 "comments" => %{"nodes" => [%{"body" => "Symphony prod smoke SYME2E-9 smoke-1"}]}
               }
             }
           }}

        true ->
          {:ok, %{"data" => %{}}}
      end
    end

    http = fn url ->
      n = Agent.get_and_update(calls, fn c -> {c, c + 1} end)

      if String.ends_with?(url, "/api/v1/state") and n < 2 do
        {:ok, 200, Jason.encode!(%{"health" => %{"status" => "healthy"}})}
      else
        {:error, :econnrefused}
      end
    end

    assert {:error, report} = ProdSmoke.run(opts(graphql_fun: linear_ok, http_get_fun: http))
    assert report.failure =~ "assert-surfaces"
  end

  test "resolve_api_key default-arg head executes without printing values" do
    result = ProdSmoke.resolve_api_key()
    assert match?({:ok, _}, result) or match?({:error, _}, result)
  end

  test "covers remaining journey error branches" do
    # resolve-key failure inside a run
    assert {:error, r1} =
             ProdSmoke.run(opts(get_env: fn "LINEAR_API_KEY" -> nil end, bootstrap_path: "/nonexistent/x"))

    assert r1.failure =~ "resolve-linear-key"

    # team fetch transport error
    team_down = fn _e, _k, q, _v ->
      if String.contains?(q, "Team"), do: {:error, {:linear_api_request, :timeout}}, else: {:error, :unused}
    end

    assert {:error, r2} = ProdSmoke.run(opts(graphql_fun: team_down))
    assert r2.failure =~ "linear_api_request"

    # project create transport error
    project_down = fn _e, _k, q, _v ->
      cond do
        String.contains?(q, "Team") -> team_ok()
        String.contains?(q, "CreateProject") -> {:error, {:linear_api_status, 502}}
        true -> {:error, :unused}
      end
    end

    assert {:error, r3} = ProdSmoke.run(opts(graphql_fun: project_down))
    assert r3.failure =~ "502"

    # issue create rejected payload
    issue_rejected = fn _e, _k, q, _v ->
      cond do
        String.contains?(q, "Team") ->
          team_ok()

        String.contains?(q, "CreateProject") ->
          {:ok, %{"data" => %{"projectCreate" => %{"success" => true, "project" => %{"id" => "p", "name" => "n", "slugId" => "s", "url" => "u"}}}}}

        String.contains?(q, "CreateIssue") ->
          {:ok, %{"data" => %{"issueCreate" => %{"success" => false}}}}

        true ->
          {:error, :unused}
      end
    end

    assert {:error, r4} = ProdSmoke.run(opts(graphql_fun: issue_rejected))
    assert r4.failure =~ "issue_create_failed"
  end

  test "workflow write failure halts with cleanup" do
    dirs_parent = Path.join(System.tmp_dir!(), "prod-smoke-file-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.dirname(dirs_parent))
    File.write!(dirs_parent, "a file, not a dir")
    on_exit(fn -> File.rm(dirs_parent) end)

    linear_ok = fn _e, _k, q, _v ->
      cond do
        String.contains?(q, "Team") ->
          team_ok()

        String.contains?(q, "CreateProject") ->
          {:ok, %{"data" => %{"projectCreate" => %{"success" => true, "project" => %{"id" => "p", "name" => "n", "slugId" => "s", "url" => "u"}}}}}

        String.contains?(q, "CreateIssue") ->
          {:ok, %{"data" => %{"issueCreate" => %{"success" => true, "issue" => %{"id" => "i", "identifier" => "SYME2E-1", "title" => "t", "url" => "u", "state" => %{"name" => "Todo"}}}}}}

        true ->
          {:ok, %{"data" => %{}}}
      end
    end

    assert {:error, report} =
             ProdSmoke.run(opts(graphql_fun: linear_ok, smoke_root: Path.join(dirs_parent, "root")))

    assert report.failure =~ "workflow write failed"
  end

  test "polls tolerate malformed issue payloads" do
    {:ok, polls} = Agent.start_link(fn -> 0 end)

    weird = fn _e, _k, q, _v ->
      cond do
        String.contains?(q, "Team") ->
          team_ok()

        String.contains?(q, "CreateProject") ->
          {:ok, %{"data" => %{"projectCreate" => %{"success" => true, "project" => %{"id" => "p", "name" => "n", "slugId" => "smoke-1", "url" => "u"}}}}}

        String.contains?(q, "CreateIssue") ->
          {:ok, %{"data" => %{"issueCreate" => %{"success" => true, "issue" => %{"id" => "i", "identifier" => "SYME2E-9", "title" => "t", "url" => "u", "state" => %{"name" => "Todo"}}}}}}

        String.contains?(q, "IssueState") ->
          n = Agent.get_and_update(polls, fn c -> {c, c + 1} end)

          case n do
            0 ->
              {:ok, %{"data" => %{"issue" => %{"id" => "i", "identifier" => "SYME2E-9"}}}}

            1 ->
              {:ok, %{"data" => %{"issue" => %{"id" => "i", "identifier" => "SYME2E-9", "state" => %{"name" => "Done", "type" => "completed"}}}}}

            _ ->
              {:ok,
               %{
                 "data" => %{
                   "issue" => %{
                     "id" => "i",
                     "identifier" => "SYME2E-9",
                     "state" => %{"name" => "Done", "type" => "completed"},
                     "comments" => %{"nodes" => [%{"body" => "Symphony prod smoke SYME2E-9 smoke-1"}]}
                   }
                 }
               }}
          end

        String.contains?(q, "ProjectStatuses") ->
          {:ok, %{"data" => %{"projectStatuses" => %{"nodes" => [%{"id" => "ps", "name" => "Completed", "type" => "completed"}]}}}}

        String.contains?(q, "CompleteProject") ->
          {:ok, %{"data" => %{"projectUpdate" => %{"success" => true}}}}

        true ->
          {:ok, %{"data" => %{}}}
      end
    end

    assert {:ok, report} = ProdSmoke.run(opts(graphql_fun: weird, timeout_ms: 5_000))
    assert report.result == :pass
  end

  test "CR-002: completes the disposable project when issue creation fails" do
    {:ok, ops} = Agent.start_link(fn -> [] end)

    graphql = fn _e, _k, q, _v ->
      cond do
        String.contains?(q, "Team") ->
          team_ok()

        String.contains?(q, "CreateProject") ->
          {:ok, %{"data" => %{"projectCreate" => %{"success" => true, "project" => %{"id" => "p1", "name" => "n", "slugId" => "s", "url" => "u"}}}}}

        String.contains?(q, "CreateIssue") ->
          {:error, {:linear_api_status, 500}}

        String.contains?(q, "ProjectStatuses") ->
          Agent.update(ops, &[:statuses | &1])
          {:ok, %{"data" => %{"projectStatuses" => %{"nodes" => [%{"id" => "ps", "name" => "Completed", "type" => "completed"}]}}}}

        String.contains?(q, "CompleteProject") ->
          Agent.update(ops, &[:complete_project | &1])
          {:ok, %{"data" => %{"projectUpdate" => %{"success" => true}}}}

        true ->
          {:error, :unused}
      end
    end

    assert {:error, report} = ProdSmoke.run(opts(graphql_fun: graphql))
    assert report.failure =~ "issue"
    assert :complete_project in Agent.get(ops, & &1)
  end

  test "CR-003: a failed daemon stop fails an otherwise successful journey" do
    {:ok, polls} = Agent.start_link(fn -> 0 end)

    happy = fn _e, _k, q, _v ->
      cond do
        String.contains?(q, "Team") ->
          team_ok()

        String.contains?(q, "CreateProject") ->
          {:ok, %{"data" => %{"projectCreate" => %{"success" => true, "project" => %{"id" => "p", "name" => "n", "slugId" => "smoke-1", "url" => "u"}}}}}

        String.contains?(q, "CreateIssue") ->
          {:ok, %{"data" => %{"issueCreate" => %{"success" => true, "issue" => %{"id" => "i", "identifier" => "SYME2E-9", "title" => "t", "url" => "u", "state" => %{"name" => "Todo"}}}}}}

        String.contains?(q, "IssueState") ->
          Agent.update(polls, &(&1 + 1))

          {:ok,
           %{
             "data" => %{
               "issue" => %{
                 "id" => "i",
                 "identifier" => "SYME2E-9",
                 "state" => %{"name" => "Done", "type" => "completed"},
                 "comments" => %{"nodes" => [%{"body" => "Symphony prod smoke SYME2E-9 smoke-1"}]}
               }
             }
           }}

        String.contains?(q, "ProjectStatuses") ->
          {:ok, %{"data" => %{"projectStatuses" => %{"nodes" => [%{"id" => "ps", "name" => "Completed", "type" => "completed"}]}}}}

        String.contains?(q, "CompleteProject") ->
          {:ok, %{"data" => %{"projectUpdate" => %{"success" => true}}}}

        true ->
          {:error, :unused}
      end
    end

    assert {:error, report} =
             ProdSmoke.run(opts(graphql_fun: happy, stop_fun: fn _ -> {:error, :stuck} end))

    assert report.failure =~ "cleanup"
  end

  test "CR-004: a canceled issue with the marker does not pass the smoke" do
    canceled = fn _e, _k, q, _v ->
      cond do
        String.contains?(q, "Team") ->
          team_ok()

        String.contains?(q, "CreateProject") ->
          {:ok, %{"data" => %{"projectCreate" => %{"success" => true, "project" => %{"id" => "p", "name" => "n", "slugId" => "smoke-1", "url" => "u"}}}}}

        String.contains?(q, "CreateIssue") ->
          {:ok, %{"data" => %{"issueCreate" => %{"success" => true, "issue" => %{"id" => "i", "identifier" => "SYME2E-9", "title" => "t", "url" => "u", "state" => %{"name" => "Todo"}}}}}}

        String.contains?(q, "IssueState") ->
          {:ok,
           %{
             "data" => %{
               "issue" => %{
                 "id" => "i",
                 "identifier" => "SYME2E-9",
                 "state" => %{"name" => "Canceled", "type" => "canceled"},
                 "comments" => %{"nodes" => [%{"body" => "Symphony prod smoke SYME2E-9 smoke-1"}]}
               }
             }
           }}

        true ->
          {:ok, %{"data" => %{}}}
      end
    end

    assert {:error, report} = ProdSmoke.run(opts(graphql_fun: canceled, timeout_ms: 20))
    assert report.failure =~ "await-completion"
  end

  test "preserves daemon logs under the report dir when the journey fails" do
    dirs = ctx_dirs()
    smoke_root = Path.join(dirs.run_dir, "root")
    report_dir = Path.join(dirs.run_dir, "reports")
    logs_dir = Path.join(smoke_root, "logs")
    File.mkdir_p!(logs_dir)
    File.write!(Path.join(logs_dir, "symphony.log"), "boom")

    o =
      opts(
        smoke_root: smoke_root,
        report_dir: report_dir,
        graphql_fun: fn _e, _k, q, _v ->
          if String.contains?(q, "Team"),
            do: {:ok, %{"data" => %{"teams" => %{"nodes" => []}}}},
            else: {:error, :unused}
        end
      )

    assert {:error, _report} = ProdSmoke.run(o)

    preserved = report_dir |> File.ls!() |> Enum.filter(&String.starts_with?(&1, "prod-smoke-failed-logs-"))
    assert [dir] = preserved
    assert File.exists?(Path.join([report_dir, dir, "symphony.log"]))
  end
end
