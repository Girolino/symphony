defmodule SymphonyElixir.ProdSmoke do
  @moduledoc """
  Production smoke journey for the Symphony harness.

  Boots the real compiled escript against a disposable Linear project/issue,
  waits for one real Codex turn to complete the issue, asserts the operator
  surfaces (`/api/v1/state` and the dashboard), always cleans up the disposable
  resources, and writes a machine-readable PASS/FAIL report under the report
  directory.

  The Linear API key is resolved exactly like the repo-owned control scripts:
  `LINEAR_API_KEY` from the environment, falling back to the documented
  bootstrap file `~/.config/linear-codex/env`. The key value is never logged
  and never written into any report or workflow file (workflow files reference
  `$LINEAR_API_KEY` and the subprocess receives it via its environment).

  All external interactions (GraphQL requests, HTTP health probes, daemon
  spawning, clock) are injectable through options so the journey logic stays
  unit-testable with fakes.
  """

  require Logger

  alias SymphonyElixir.OpsTransport

  @default_port 4799
  # A real Codex turn shares one host with the always-on lane daemon and the
  # rate-limited Linear API; under contention completion legitimately takes
  # well over 5 minutes. The smoke is a correctness check, not a latency SLA,
  # so it stays patient rather than failing an otherwise-good release (the
  # single-host coupling residual). Rollback still protects against a genuinely
  # broken release — this only stops flaky timeouts from blocking the pin.
  @default_timeout_ms 900_000
  @default_health_timeout_ms 60_000
  @default_poll_interval_ms 15_000
  @default_team_key "SYM"
  @linear_endpoint "https://api.linear.app/graphql"

  @team_query """
  query SymphonyProdSmokeTeam($key: String!) {
    teams(filter: {key: {eq: $key}}, first: 1) {
      nodes {
        id
        key
        name
        states(first: 50) {
          nodes {
            id
            name
            position
            type
          }
        }
      }
    }
  }
  """

  @create_project_mutation """
  mutation SymphonyProdSmokeCreateProject($name: String!, $teamIds: [String!]!) {
    projectCreate(input: {name: $name, teamIds: $teamIds}) {
      success
      project {
        id
        name
        slugId
        url
      }
    }
  }
  """

  @create_issue_mutation """
  mutation SymphonyProdSmokeCreateIssue(
    $teamId: String!
    $projectId: String!
    $title: String!
    $description: String!
    $stateId: String
  ) {
    issueCreate(
      input: {
        teamId: $teamId
        projectId: $projectId
        title: $title
        description: $description
        stateId: $stateId
      }
    ) {
      success
      issue {
        id
        identifier
        title
        url
        state {
          name
        }
      }
    }
  }
  """

  @issue_state_query """
  query SymphonyProdSmokeIssueState($id: String!) {
    issue(id: $id) {
      id
      identifier
      state {
        name
        type
      }
      comments(first: 20) {
        nodes {
          body
        }
      }
    }
  }
  """

  @project_statuses_query """
  query SymphonyProdSmokeProjectStatuses {
    projectStatuses(first: 50) {
      nodes {
        id
        name
        type
      }
    }
  }
  """

  @complete_project_mutation """
  mutation SymphonyProdSmokeCompleteProject($id: String!, $statusId: String!, $completedAt: DateTime!) {
    projectUpdate(id: $id, input: {statusId: $statusId, completedAt: $completedAt}) {
      success
    }
  }
  """

  @cancel_issue_mutation """
  mutation SymphonyProdSmokeCancelIssue($id: String!, $stateId: String!) {
    issueUpdate(id: $id, input: {stateId: $stateId}) {
      success
    }
  }
  """

  @type step :: %{
          name: String.t(),
          status: :pass | :fail | :skip,
          duration_ms: non_neg_integer(),
          detail: String.t() | nil
        }

  @type report :: %{
          result: :pass | :fail,
          started_at: String.t(),
          finished_at: String.t(),
          duration_ms: non_neg_integer(),
          steps: [step()],
          issue: map() | nil,
          daemon: map() | nil,
          failure: String.t() | nil
        }

  @doc """
  Runs the full production smoke journey.

  Returns `{:ok, report}` on PASS and `{:error, report}` on FAIL. The report is
  always written to the report directory before returning.
  """
  @spec run(keyword()) :: {:ok, report()} | {:error, report()}
  def run(opts) do
    started_at = DateTime.utc_now()
    context = build_context(opts)

    {steps, meta} = execute_journey(context)

    report = build_report(steps, started_at, DateTime.utc_now(), meta)
    report_path = write_report!(report, context.report_dir)
    Logger.info("prod.smoke report written to #{report_path}")

    case report.result do
      :pass -> {:ok, report}
      :fail -> {:error, report}
    end
  end

  @doc """
  Parses the documented Linear bootstrap env file contents and extracts the
  `LINEAR_API_KEY` value. Never logs the value.
  """
  @spec parse_api_key_file(String.t()) :: {:ok, String.t()} | {:error, :missing_key}
  def parse_api_key_file(contents) when is_binary(contents) do
    case Regex.run(~r/^LINEAR_API_KEY=(.*)$/m, contents) do
      [_, raw] ->
        key = raw |> String.trim() |> String.trim("\"") |> String.trim("'")
        if key == "", do: {:error, :missing_key}, else: {:ok, key}

      _ ->
        {:error, :missing_key}
    end
  end

  @doc """
  Resolves the Linear API key by name: environment first, bootstrap file second.
  """
  @spec resolve_api_key((String.t() -> String.t() | nil), String.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def resolve_api_key(get_env \\ &System.get_env/1, bootstrap_path \\ default_bootstrap_path()) do
    case get_env.("LINEAR_API_KEY") do
      value when is_binary(value) and value != "" ->
        {:ok, value}

      _ ->
        with true <- File.exists?(bootstrap_path),
             {:ok, contents} <- File.read(bootstrap_path),
             {:ok, key} <- parse_api_key_file(contents) do
          {:ok, key}
        else
          _ ->
            {:error,
             "LINEAR_API_KEY is not set and #{bootstrap_path} does not provide it " <>
               "(capability checked by name only)"}
        end
    end
  end

  @doc """
  Renders the disposable smoke `WORKFLOW.md` contents. The API key is always
  referenced as `$LINEAR_API_KEY`, never inlined.
  """
  @spec render_workflow(map()) :: String.t()
  def render_workflow(%{
        project_slug: project_slug,
        active_states: active_states,
        terminal_states: terminal_states,
        workspace_root: workspace_root,
        prompt: prompt
      }) do
    """
    ---
    tracker:
      kind: linear
      endpoint: #{@linear_endpoint}
      api_key: $LINEAR_API_KEY
      project_slug: "#{project_slug}"
      active_states:
    #{yaml_list(active_states, 4)}
      terminal_states:
    #{yaml_list(terminal_states, 4)}
    polling:
      interval_ms: 20000
    workspace:
      root: #{workspace_root}
    hooks:
      after_create: |
        git init -q
        git config user.name "Symphony Prod Smoke"
        git config user.email "symphony-prod-smoke@example.invalid"
        printf '%s\\n' "Symphony prod smoke workspace" > README.md
        git add README.md
        git -c commit.gpgSign=false \
          -c core.hooksPath=.git/symphony-prod-smoke-no-hooks \
          commit --no-verify -q -m "Initialize prod smoke workspace"
    agent:
      max_concurrent_agents: 1
      max_turns: 3
    codex:
      command: codex app-server
      approval_policy: never
      thread_sandbox: workspace-write
      turn_timeout_ms: 240000
      stall_timeout_ms: 240000
    observability:
      enabled: false
    ---

    #{prompt}
    """
  end

  @doc """
  The single-turn, self-completing smoke prompt. Kept intentionally frugal with
  Linear API calls because the workspace shares a rate-limited API budget with
  the live lanes.
  """
  @spec smoke_prompt(String.t()) :: String.t()
  def smoke_prompt(marker) when is_binary(marker) do
    """
    You are running the Symphony production smoke check. This is an unattended
    session; never ask for approval or human follow-up.

    Complete these steps with the `linear_graphql` tool, using as few API calls
    as possible:

    1. Query the current issue `{{ issue.id }}` once to read its comments and
       the team workflow states:

    ```graphql
    query IssueContext($id: String!) {
      issue(id: $id) {
        comments(first: 20) { nodes { body } }
        team { states(first: 50) { nodes { id name type } } }
      }
    }
    ```

    2. Unless it is already present, post exactly one comment on the current
       issue with this exact body:
    #{marker}

    ```graphql
    mutation AddComment($issueId: String!, $body: String!) {
      commentCreate(input: {issueId: $issueId, body: $body}) { success }
    }
    ```

    3. Move the current issue to a workflow state whose `type` is `completed`:

    ```graphql
    mutation CompleteIssue($id: String!, $stateId: String!) {
      issueUpdate(id: $id, input: {stateId: $stateId}) { success }
    }
    ```

    Stop only after the comment exists and the issue is in a completed state.
    """
  end

  @doc """
  Derives the overall result from recorded steps: any failed step fails the run.
  """
  @spec derive_result([step()]) :: :pass | :fail
  def derive_result(steps) when is_list(steps) do
    if Enum.any?(steps, &(&1.status == :fail)), do: :fail, else: :pass
  end

  @doc """
  Builds the machine-readable report map.
  """
  @spec build_report([step()], DateTime.t(), DateTime.t(), map()) :: report()
  def build_report(steps, started_at, finished_at, meta) do
    %{
      result: derive_result(steps),
      started_at: DateTime.to_iso8601(started_at),
      finished_at: DateTime.to_iso8601(finished_at),
      duration_ms: DateTime.diff(finished_at, started_at, :millisecond),
      steps: steps,
      issue: Map.get(meta, :issue),
      daemon: Map.get(meta, :daemon),
      failure: failure_detail(steps)
    }
  end

  @doc """
  Deterministic report path for a given timestamp.
  """
  @spec report_path(String.t(), DateTime.t()) :: String.t()
  def report_path(report_dir, %DateTime{} = at) do
    stamp =
      at
      |> DateTime.truncate(:second)
      |> DateTime.to_iso8601()
      |> String.replace(~r/[:+]/, "-")

    Path.join(report_dir, "prod-smoke-#{stamp}.json")
  end

  @spec default_bootstrap_path() :: String.t()
  def default_bootstrap_path do
    Path.join([System.user_home!(), ".config", "linear-codex", "env"])
  end

  # ── Journey ──────────────────────────────────────────────────────────────

  defp build_context(opts) do
    port = Keyword.get(opts, :port, @default_port)
    root = Keyword.get(opts, :smoke_root, Path.join(System.tmp_dir!(), smoke_run_id()))
    get_env = Keyword.get(opts, :get_env, &System.get_env/1)

    team_key =
      case Keyword.fetch(opts, :team_key) do
        {:ok, value} -> value
        :error -> get_env.("SYMPHONY_LIVE_LINEAR_TEAM_KEY") || @default_team_key
      end

    %{
      port: port,
      timeout_ms: Keyword.get(opts, :timeout_ms, @default_timeout_ms),
      health_timeout_ms: Keyword.get(opts, :health_timeout_ms, @default_health_timeout_ms),
      poll_interval_ms: Keyword.get(opts, :poll_interval_ms, @default_poll_interval_ms),
      team_key: team_key,
      report_dir: Keyword.get(opts, :report_dir, default_report_dir()),
      escript_path: Keyword.get(opts, :escript_path, Path.join(File.cwd!(), "bin/symphony")),
      smoke_root: root,
      graphql_fun: Keyword.get(opts, :graphql_fun, &OpsTransport.graphql/4),
      http_get_fun: Keyword.get(opts, :http_get_fun, &OpsTransport.http_get/1),
      spawn_fun: Keyword.get(opts, :spawn_fun, &OpsTransport.spawn_daemon/4),
      stop_fun: Keyword.get(opts, :stop_fun, &OpsTransport.stop_daemon/1),
      sleep_fun: Keyword.get(opts, :sleep_fun, &Process.sleep/1),
      get_env: get_env,
      bootstrap_path: Keyword.get(opts, :bootstrap_path, default_bootstrap_path())
    }
  end

  defp execute_journey(context) do
    initial = %{steps: [], meta: %{}, api_key: nil, linear: nil, daemon: nil}

    with {:ok, state} <- step_resolve_key(initial, context),
         {:ok, state} <- step_preflight(state, context),
         {:ok, state} <- step_linear_setup(state, context),
         {:ok, state} <- step_write_workflow(state, context),
         {:ok, state} <- step_boot_daemon(state, context),
         {:ok, state} <- step_await_health(state, context),
         {:ok, state} <- step_await_completion(state, context),
         {:ok, state} <- step_assert_surfaces(state, context) do
      finalize(state, context)
    else
      {:halt, state} -> finalize(state, context)
    end
  end

  # Cleanup receives the full accumulated run state regardless of where the
  # journey halted, so a daemon or disposable project is never orphaned.
  defp finalize(state, context) do
    steps = cleanup(state.steps, context, state.api_key, state.linear, state.daemon)
    {Enum.reverse(steps), state.meta}
  end

  defp record_step(state, name, status, elapsed, detail) do
    %{state | steps: [step(name, status, elapsed, detail) | state.steps]}
  end

  defp continue_or_halt(state, :pass), do: {:ok, state}
  defp continue_or_halt(state, _status), do: {:halt, state}

  defp step_resolve_key(state, context) do
    {status, detail, elapsed, key} =
      timed(fn ->
        case resolve_api_key(context.get_env, context.bootstrap_path) do
          {:ok, key} -> {:pass, "LINEAR_API_KEY capability available (by name)", key}
          {:error, message} -> {:fail, message, nil}
        end
      end)

    state = %{record_step(state, "resolve-linear-key", status, elapsed, detail) | api_key: key}
    continue_or_halt(state, status)
  end

  defp step_preflight(state, context) do
    {status, detail, elapsed, _} =
      timed(fn ->
        cond do
          not File.exists?(context.escript_path) ->
            {:fail, "escript missing at #{context.escript_path}; run `mix build` first", nil}

          not port_free?(context.port) ->
            {:fail, "port #{context.port} is already in use", nil}

          true ->
            {:pass, "escript present, port #{context.port} free", nil}
        end
      end)

    state = record_step(state, "preflight", status, elapsed, detail)
    continue_or_halt(state, status)
  end

  # Accumulates each created resource into `linear` as soon as it exists, so a
  # later setup failure still hands the partial state to cleanup (a project
  # whose issue creation failed must still be completed, not orphaned).
  defp step_linear_setup(state, context) do
    {status, detail, elapsed, linear} =
      timed(fn ->
        with {:team, {:ok, team}, acc} <- {:team, fetch_team(context, state.api_key), %{}},
             acc = Map.put(acc, :team, team),
             {:project, {:ok, project}, acc} <- {:project, create_project(context, state.api_key, team), acc},
             acc = Map.put(acc, :project, project),
             {:issue, {:ok, issue}, acc} <- {:issue, create_issue(context, state.api_key, team, project), acc} do
          marker = "Symphony prod smoke #{issue["identifier"]} #{project["slugId"]}"
          acc = acc |> Map.put(:issue, issue) |> Map.put(:marker, marker)
          {:pass, "disposable issue #{issue["identifier"]} created", acc}
        else
          {stage, {:error, reason}, acc} ->
            {:fail, "linear setup failed at #{stage}: #{inspect(reason)}", acc}
        end
      end)

    linear = if linear == %{}, do: nil, else: linear
    state = %{record_step(state, "linear-setup", status, elapsed, detail) | linear: linear}

    state =
      case linear do
        %{issue: issue} ->
          put_in(state, [:meta, :issue], %{"identifier" => issue["identifier"], "url" => issue["url"]})

        _ ->
          state
      end

    continue_or_halt(state, status)
  end

  defp step_write_workflow(state, context) do
    {status, detail, elapsed, _} =
      timed(fn ->
        workflow = smoke_workflow_contents(context, state.linear)
        workflow_path = Path.join(context.smoke_root, "WORKFLOW.md")

        with :ok <- File.mkdir_p(context.smoke_root),
             :ok <- File.mkdir_p(Path.join(context.smoke_root, "workspaces")),
             :ok <- File.write(workflow_path, workflow) do
          {:pass, "smoke workflow written", nil}
        else
          {:error, reason} -> {:fail, "workflow write failed: #{inspect(reason)}", nil}
        end
      end)

    state = record_step(state, "write-workflow", status, elapsed, detail)
    continue_or_halt(state, status)
  end

  defp step_boot_daemon(state, context) do
    {status, detail, elapsed, daemon} =
      timed(fn ->
        workflow_path = Path.join(context.smoke_root, "WORKFLOW.md")
        logs_root = Path.join(context.smoke_root, "logs")

        case context.spawn_fun.(context.escript_path, workflow_path, context.port, %{
               "LINEAR_API_KEY" => state.api_key,
               "LOGS_ROOT" => logs_root
             }) do
          {:ok, daemon} -> {:pass, "daemon booting on port #{context.port}", daemon}
          {:error, reason} -> {:fail, "daemon spawn failed: #{inspect(reason)}", nil}
        end
      end)

    state = %{record_step(state, "boot-daemon", status, elapsed, detail) | daemon: daemon}
    state = put_in(state, [:meta, :daemon], %{"port" => context.port})
    continue_or_halt(state, status)
  end

  defp step_await_health(state, context) do
    {status, detail, elapsed, _} =
      timed(fn ->
        await(context, context.health_timeout_ms, 1_000, fn -> health_probe(context) end)
        |> case do
          {:done, :healthy} -> {:pass, "/api/v1/state healthy", nil}
          :timeout -> {:fail, "daemon did not become healthy within #{context.health_timeout_ms}ms", nil}
        end
      end)

    state = record_step(state, "await-health", status, elapsed, detail)
    continue_or_halt(state, status)
  end

  defp health_probe(context) do
    with {:ok, 200, body} <- context.http_get_fun.(state_url(context.port)),
         {:ok, %{"health" => %{"status" => "healthy"}}} <- Jason.decode(body) do
      {:done, :healthy}
    else
      _ -> :retry
    end
  end

  defp step_await_completion(state, context) do
    issue_id = get_in(state.linear, [:issue, "id"])
    marker = state.linear.marker

    {status, detail, elapsed, outcome} =
      timed(fn ->
        await(context, context.timeout_ms, context.poll_interval_ms, fn ->
          completion_probe(context, state.api_key, issue_id, marker)
        end)
        |> case do
          {:done, issue} ->
            {:pass, "issue #{issue["identifier"]} completed by real Codex turn with marker comment", issue}

          :timeout ->
            {:fail, "issue did not reach completed-with-comment within #{context.timeout_ms}ms", nil}
        end
      end)

    state = record_step(state, "await-completion", status, elapsed, detail)

    state =
      update_in(state, [:meta, :issue], fn issue_meta ->
        Map.put(issue_meta || %{}, "final_state", outcome && get_in(outcome, ["state", "name"]))
      end)

    continue_or_halt(state, status)
  end

  defp step_assert_surfaces(state, context) do
    {status, detail, elapsed, _} =
      timed(fn ->
        with {:ok, 200, state_body} <- context.http_get_fun.(state_url(context.port)),
             {:ok, %{"health" => %{"status" => "healthy"}}} <- Jason.decode(state_body),
             {:ok, 200, dashboard_body} <- context.http_get_fun.("http://127.0.0.1:#{context.port}/"),
             true <- byte_size(dashboard_body) > 0 do
          {:pass, "state healthy and dashboard serving after journey", nil}
        else
          other -> {:fail, "operator surface assertion failed: #{inspect(other)}", nil}
        end
      end)

    state = record_step(state, "assert-surfaces", status, elapsed, detail)
    continue_or_halt(state, status)
  end

  # Cleanup always runs for whatever exists, never raises, and records a step.
  defp cleanup(steps, context, api_key, linear, daemon) do
    {status, detail, elapsed, _} =
      timed(fn ->
        journey_failed? = Enum.any?(steps, &(&1.status == :fail))
        daemon_result = cleanup_daemon(context, daemon)
        issue_result = cleanup_issue(context, api_key, linear, journey_failed?)
        project_result = cleanup_project(context, api_key, linear)
        logs_result = preserve_logs_on_failure(steps, context)
        fs_result = safe(fn -> File.rm_rf!(context.smoke_root) end)

        # A leaked daemon or open disposable project must fail the journey —
        # a promotion cannot be declared live over an unfinished cleanup.
        # Log preservation is diagnostic-only and never fails the run.
        cleanup_status =
          if cleanup_ok?(:daemon, daemon_result) and cleanup_ok?(:issue, issue_result) and
               cleanup_ok?(:project, project_result) and cleanup_ok?(:fs, fs_result) do
            :pass
          else
            :fail
          end

        {cleanup_status,
         "daemon=#{inspect(daemon_result)} issue=#{inspect(issue_result)} " <>
           "project=#{inspect(project_result)} " <>
           "logs=#{inspect(logs_result)} fs=#{inspect(fs_result)}", nil}
      end)

    [step("cleanup", status, elapsed, detail) | steps]
  end

  # A failed journey must not leave its disposable issue in an active state:
  # completing the project does not transition its issues.
  defp cleanup_issue(context, api_key, %{issue: %{"id" => issue_id}, team: team}, true)
       when is_binary(api_key) do
    safe(fn ->
      canceled_state =
        team
        |> get_in(["states", "nodes"])
        |> List.wrap()
        |> Enum.find(&(&1["type"] == "canceled"))

      case canceled_state do
        %{"id" => state_id} ->
          context.graphql_fun.(@linear_endpoint, api_key, @cancel_issue_mutation, %{
            id: issue_id,
            stateId: state_id
          })

        nil ->
          {:error, :no_canceled_state}
      end
    end)
  end

  defp cleanup_issue(_context, _api_key, _linear, _journey_failed?), do: :skipped

  defp cleanup_ok?(_kind, :skipped), do: true
  defp cleanup_ok?(:daemon, :ok), do: true
  defp cleanup_ok?(:issue, {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}), do: true

  defp cleanup_ok?(:project, {:ok, %{"data" => %{"projectUpdate" => %{"success" => true}}}}), do: true

  defp cleanup_ok?(:fs, paths) when is_list(paths), do: true
  defp cleanup_ok?(_kind, _result), do: false

  # A FAIL report without the daemon's own logs cannot be triaged by an agent,
  # so failed journeys keep their logs under the report directory.
  defp preserve_logs_on_failure(steps, context) do
    logs_dir = Path.join(context.smoke_root, "logs")

    if Enum.any?(steps, &(&1.status == :fail)) and File.dir?(logs_dir) do
      safe(fn ->
        dest = Path.join(context.report_dir, "prod-smoke-failed-logs-#{System.unique_integer([:positive])}")
        File.mkdir_p!(context.report_dir)
        File.cp_r!(logs_dir, dest)
        dest
      end)
    else
      :skipped
    end
  end

  defp completion_probe(context, api_key, issue_id, marker) do
    with {:ok, %{"data" => %{"issue" => issue}}} when is_map(issue) <-
           context.graphql_fun.(@linear_endpoint, api_key, @issue_state_query, %{id: issue_id}),
         true <- completed?(issue) and has_comment?(issue, marker) do
      {:done, issue}
    else
      _ -> :retry
    end
  end

  defp cleanup_daemon(_context, nil), do: :skipped
  defp cleanup_daemon(context, daemon), do: safe(fn -> context.stop_fun.(daemon) end)

  defp cleanup_project(context, api_key, %{project: %{"id" => project_id}}) when is_binary(api_key) do
    safe(fn -> complete_project(context, api_key, project_id) end)
  end

  defp cleanup_project(_context, _api_key, _linear), do: :skipped

  # ── Linear operations ────────────────────────────────────────────────────

  defp fetch_team(context, api_key) do
    case context.graphql_fun.(@linear_endpoint, api_key, @team_query, %{key: context.team_key}) do
      {:ok, %{"data" => %{"teams" => %{"nodes" => [team | _]}}}} -> {:ok, team}
      {:ok, payload} -> {:error, {:team_not_found, context.team_key, redact_payload(payload)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_project(context, api_key, team) do
    name = "Symphony Prod Smoke #{System.unique_integer([:positive])}"

    case context.graphql_fun.(@linear_endpoint, api_key, @create_project_mutation, %{
           teamIds: [team["id"]],
           name: name
         }) do
      {:ok, %{"data" => %{"projectCreate" => %{"success" => true, "project" => project}}}} -> {:ok, project}
      {:ok, payload} -> {:error, {:project_create_failed, redact_payload(payload)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_issue(context, api_key, team, project) do
    initial_state =
      team
      |> get_in(["states", "nodes"])
      |> List.wrap()
      |> initial_issue_state()

    title = "Symphony prod smoke for #{project["name"]}"

    case context.graphql_fun.(@linear_endpoint, api_key, @create_issue_mutation, %{
           teamId: team["id"],
           projectId: project["id"],
           title: title,
           description: title,
           stateId: initial_state && initial_state["id"]
         }) do
      {:ok, %{"data" => %{"issueCreate" => %{"success" => true, "issue" => issue}}}} -> {:ok, issue}
      {:ok, payload} -> {:error, {:issue_create_failed, redact_payload(payload)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp complete_project(context, api_key, project_id) do
    with {:ok, %{"data" => %{"projectStatuses" => %{"nodes" => statuses}}}} <-
           context.graphql_fun.(@linear_endpoint, api_key, @project_statuses_query, %{}),
         %{"id" => status_id} <- Enum.find(statuses, &(&1["type"] == "completed")) do
      completed_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

      context.graphql_fun.(@linear_endpoint, api_key, @complete_project_mutation, %{
        id: project_id,
        statusId: status_id,
        completedAt: completed_at
      })
    end
  end

  defp smoke_workflow_contents(context, linear) do
    team = linear.team

    active_states =
      team
      |> get_in(["states", "nodes"])
      |> List.wrap()
      |> Enum.filter(&(&1["type"] in ["unstarted", "started"]))
      |> Enum.sort_by(&state_order_key/1)
      |> Enum.map(& &1["name"])
      |> non_empty(["Todo", "In Progress"])

    terminal_states =
      team
      |> get_in(["states", "nodes"])
      |> List.wrap()
      |> Enum.filter(&(&1["type"] in ["completed", "canceled", "duplicate"]))
      |> Enum.sort_by(&state_order_key/1)
      |> Enum.map(& &1["name"])
      |> non_empty(["Done", "Canceled", "Duplicate"])

    render_workflow(%{
      project_slug: get_in(linear, [:project, "slugId"]),
      active_states: active_states,
      terminal_states: terminal_states,
      workspace_root: Path.join(context.smoke_root, "workspaces"),
      prompt: smoke_prompt(linear.marker)
    })
  end

  # ── Small utilities ──────────────────────────────────────────────────────

  defp write_report!(report, report_dir) do
    File.mkdir_p!(report_dir)
    path = report_path(report_dir, DateTime.utc_now())
    File.write!(path, Jason.encode!(jsonable(report), pretty: true))
    path
  end

  defp jsonable(report) do
    update_in(report, [:steps], fn steps ->
      Enum.map(steps, &Map.update!(&1, :status, fn status -> Atom.to_string(status) end))
    end)
    |> Map.update!(:result, &Atom.to_string/1)
  end

  defp failure_detail(steps) do
    steps
    |> Enum.find(&(&1.status == :fail))
    |> case do
      nil -> nil
      %{name: name, detail: detail} -> "#{name}: #{detail}"
    end
  end

  defp await(context, timeout_ms, interval_ms, fun) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await(context, deadline, interval_ms, fun)
  end

  defp do_await(context, deadline, interval_ms, fun) do
    case fun.() do
      {:done, value} ->
        {:done, value}

      :retry ->
        if System.monotonic_time(:millisecond) >= deadline do
          :timeout
        else
          context.sleep_fun.(interval_ms)
          do_await(context, deadline, interval_ms, fun)
        end
    end
  end

  defp timed(fun) do
    started = System.monotonic_time(:millisecond)
    {status, detail, value} = fun.()
    {status, detail, System.monotonic_time(:millisecond) - started, value}
  end

  defp step(name, status, duration_ms, detail) do
    %{name: name, status: status, duration_ms: duration_ms, detail: detail}
  end

  defp safe(fun) do
    fun.()
  catch
    _kind, reason -> {:caught, reason}
  end

  # Only a genuinely completed state proves the journey; a canceled issue with
  # the marker comment must NOT pass the smoke.
  defp completed?(%{"state" => %{"type" => "completed"}}), do: true
  defp completed?(_issue), do: false

  defp has_comment?(%{"comments" => %{"nodes" => nodes}}, marker) when is_list(nodes) do
    Enum.any?(nodes, &(&1["body"] == marker))
  end

  defp has_comment?(_issue, _marker), do: false

  defp non_empty([], fallback), do: fallback
  defp non_empty(list, _fallback), do: list

  defp initial_issue_state(states) when is_list(states) do
    states
    |> Enum.filter(&(&1["type"] == "unstarted"))
    |> Enum.sort_by(&state_order_key/1)
    |> List.first()
    |> case do
      nil ->
        states
        |> Enum.filter(&(&1["type"] == "started"))
        |> Enum.sort_by(&state_order_key/1)
        |> List.first()

      state ->
        state
    end
  end

  defp state_order_key(%{"position" => position, "name" => name}) when is_number(position) do
    {0, position, String.downcase(to_string(name || ""))}
  end

  defp state_order_key(%{"name" => name}) do
    {1, 0, String.downcase(to_string(name || ""))}
  end

  defp yaml_list(items, indent) do
    prefix = String.duplicate(" ", indent)
    Enum.map_join(items, "\n", &"#{prefix}- \"#{&1}\"")
  end

  defp state_url(port), do: "http://127.0.0.1:#{port}/api/v1/state"

  defp port_free?(port) do
    case :gen_tcp.listen(port, [:binary, ip: {127, 0, 0, 1}]) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, _reason} ->
        false
    end
  end

  defp smoke_run_id, do: "symphony-prod-smoke-#{System.unique_integer([:positive])}"

  defp default_report_dir do
    File.cwd!() |> Path.join("..") |> Path.expand() |> Path.join("qa-output")
  end

  defp redact_payload(payload) do
    payload
    |> inspect(limit: 10, printable_limit: 500)
  end
end
