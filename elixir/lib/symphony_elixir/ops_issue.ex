defmodule SymphonyElixir.OpsIssue do
  @moduledoc """
  Files operational Linear issues for the autonomy machinery (promote failures,
  smoke failures, breaker parks, watchdog events).

  Guarantees:

  * Deduplicates by exact title among non-terminal issues in the target team —
    re-filing the same failure class updates nothing and returns the existing
    issue, so every FAIL maps to exactly one open issue.
  * Attaches the issue to the configured project when the project can be
    resolved by slug; otherwise files it team-only rather than losing it.
  * Resolves the Linear API key by name via `SymphonyElixir.ProdSmoke.resolve_api_key/2`
    semantics; never logs the value.
  """

  alias SymphonyElixir.OpsTransport
  alias SymphonyElixir.ProdSmoke

  @linear_endpoint "https://api.linear.app/graphql"
  @default_team_key "SYME2E"

  @find_issue_query """
  query SymphonyOpsFindIssue($teamKey: String!, $title: String!) {
    issues(
      filter: {
        team: {key: {eq: $teamKey}}
        title: {eq: $title}
        state: {type: {nin: ["completed", "canceled"]}}
      }
      first: 1
    ) {
      nodes {
        id
        identifier
        url
      }
    }
  }
  """

  @team_query """
  query SymphonyOpsTeam($key: String!) {
    teams(filter: {key: {eq: $key}}, first: 1) {
      nodes {
        id
        key
        states(first: 50) {
          nodes {
            id
            name
            type
          }
        }
      }
    }
  }
  """

  @find_project_query """
  query SymphonyOpsProject($slug: String!) {
    projects(filter: {slugId: {eq: $slug}}, first: 1) {
      nodes {
        id
        slugId
      }
    }
  }
  """

  @create_issue_mutation """
  mutation SymphonyOpsCreateIssue(
    $teamId: String!
    $title: String!
    $description: String!
    $projectId: String
    $stateId: String
  ) {
    issueCreate(
      input: {teamId: $teamId, title: $title, description: $description, projectId: $projectId, stateId: $stateId}
    ) {
      success
      issue {
        id
        identifier
        url
      }
    }
  }
  """

  @type result :: {:created | :existing, map()} | {:error, term()}

  @doc """
  Files (or finds) the operational issue for `title`, with `body` as the
  description. Options:

    * `:team_key` — Linear team key (default #{@default_team_key})
    * `:project_slug` — project slugId to attach to (optional)
    * `:graphql_fun` — injectable GraphQL transport for tests
    * `:get_env` / `:bootstrap_path` — injectable key resolution for tests
  """
  @spec file(String.t(), String.t(), keyword()) :: result()
  def file(title, body, opts) when is_binary(title) and is_binary(body) do
    graphql_fun = Keyword.get(opts, :graphql_fun, &OpsTransport.graphql/4)
    team_key = Keyword.get(opts, :team_key, System.get_env("SYMPHONY_OPS_TEAM_KEY") || @default_team_key)
    project_slug = Keyword.get(opts, :project_slug, System.get_env("SYMPHONY_OPS_PROJECT_SLUG"))
    get_env = Keyword.get(opts, :get_env, &System.get_env/1)
    bootstrap_path = Keyword.get(opts, :bootstrap_path, ProdSmoke.default_bootstrap_path())

    with {:ok, api_key} <- ProdSmoke.resolve_api_key(get_env, bootstrap_path),
         {:ok, nil} <- find_existing(graphql_fun, api_key, team_key, title),
         {:ok, team} <- fetch_team(graphql_fun, api_key, team_key) do
      project_id = resolve_project_id(graphql_fun, api_key, project_slug)
      create_issue(graphql_fun, api_key, team, project_id, title, body)
    else
      {:ok, %{} = issue} -> {:existing, issue}
      {:error, reason} -> {:error, reason}
    end
  end

  # A failed dedup lookup must NOT be read as "no issue exists" — creating on
  # top of a transient error would break the exactly-one-open-issue guarantee.
  defp find_existing(graphql_fun, api_key, team_key, title) do
    case graphql_fun.(@linear_endpoint, api_key, @find_issue_query, %{teamKey: team_key, title: title}) do
      {:ok, %{"data" => %{"issues" => %{"nodes" => [issue | _]}}}} -> {:ok, issue}
      {:ok, %{"data" => %{"issues" => %{"nodes" => []}}}} -> {:ok, nil}
      {:ok, payload} -> {:error, {:dedup_lookup_failed, inspect(payload, limit: 5)}}
      {:error, reason} -> {:error, {:dedup_lookup_failed, reason}}
    end
  end

  defp fetch_team(graphql_fun, api_key, team_key) do
    case graphql_fun.(@linear_endpoint, api_key, @team_query, %{key: team_key}) do
      {:ok, %{"data" => %{"teams" => %{"nodes" => [%{"id" => _} = team | _]}}}} -> {:ok, team}
      {:ok, payload} -> {:error, {:team_not_found, team_key, inspect(payload, limit: 5)}}
      {:error, reason} -> {:error, reason}
    end
  end

  # New issues must land in a dispatchable (unstarted) state: teams default to
  # Backlog, which lanes deliberately exclude from active_states.
  defp dispatchable_state_id(team) do
    team
    |> get_in(["states", "nodes"])
    |> List.wrap()
    |> Enum.find(&(&1["type"] == "unstarted"))
    |> case do
      %{"id" => id} -> id
      nil -> nil
    end
  end

  defp resolve_project_id(_graphql_fun, _api_key, nil), do: nil

  defp resolve_project_id(graphql_fun, api_key, slug) do
    case graphql_fun.(@linear_endpoint, api_key, @find_project_query, %{slug: slug}) do
      {:ok, %{"data" => %{"projects" => %{"nodes" => [%{"id" => id} | _]}}}} -> id
      _ -> nil
    end
  end

  defp create_issue(graphql_fun, api_key, team, project_id, title, body) do
    variables = %{
      teamId: team["id"],
      title: title,
      description: body,
      projectId: project_id,
      stateId: dispatchable_state_id(team)
    }

    case graphql_fun.(@linear_endpoint, api_key, @create_issue_mutation, variables) do
      {:ok, %{"data" => %{"issueCreate" => %{"success" => true, "issue" => issue}}}} ->
        {:created, issue}

      {:ok, payload} ->
        {:error, {:issue_create_failed, inspect(payload, limit: 5)}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
