defmodule SymphonyElixir.Linear.Client do
  @moduledoc """
  Thin Linear GraphQL client for polling candidate issues.
  """

  require Logger
  alias SymphonyElixir.Config
  alias SymphonyElixir.Linear.{Auth, Issue}

  @issue_page_size 50
  @max_error_body_log_bytes 1_000

  @query """
  query SymphonyLinearPoll($projectSlug: String!, $stateNames: [String!]!, $first: Int!, $relationFirst: Int!, $after: String) {
    issues(filter: {project: {slugId: {eq: $projectSlug}}, state: {name: {in: $stateNames}}}, first: $first, after: $after) {
      nodes {
        id
        identifier
        title
        description
        priority
        state {
          name
        }
        branchName
        url
        assignee {
          id
        }
        labels {
          nodes {
            name
          }
        }
        inverseRelations(first: $relationFirst) {
          nodes {
            type
            issue {
              id
              identifier
              state {
                name
              }
            }
          }
        }
        createdAt
        updatedAt
      }
      pageInfo {
        hasNextPage
        endCursor
      }
    }
  }
  """

  @query_by_ids """
  query SymphonyLinearIssuesById($ids: [ID!]!, $first: Int!, $relationFirst: Int!) {
    issues(filter: {id: {in: $ids}}, first: $first) {
      nodes {
        id
        identifier
        title
        description
        priority
        state {
          name
        }
        branchName
        url
        assignee {
          id
        }
        labels {
          nodes {
            name
          }
        }
        inverseRelations(first: $relationFirst) {
          nodes {
            type
            issue {
              id
              identifier
              state {
                name
              }
            }
          }
        }
        createdAt
        updatedAt
      }
    }
  }
  """

  @viewer_query """
  query SymphonyLinearViewer {
    viewer {
      id
    }
  }
  """

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    tracker = Config.settings!().tracker
    project_slug = tracker.project_slug

    cond do
      not auth_configured?(tracker.api_key) ->
        {:error, :missing_linear_api_token}

      is_nil(project_slug) ->
        {:error, :missing_linear_project_slug}

      true ->
        with {:ok, assignee_filter} <- routing_assignee_filter() do
          do_fetch_by_states(project_slug, tracker.active_states, assignee_filter)
        end
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    normalized_states = Enum.map(state_names, &to_string/1) |> Enum.uniq()

    if normalized_states == [] do
      {:ok, []}
    else
      tracker = Config.settings!().tracker
      project_slug = tracker.project_slug

      cond do
        not auth_configured?(tracker.api_key) ->
          {:error, :missing_linear_api_token}

        is_nil(project_slug) ->
          {:error, :missing_linear_project_slug}

        true ->
          do_fetch_by_states(project_slug, normalized_states, nil)
      end
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    ids = Enum.uniq(issue_ids)

    case ids do
      [] ->
        {:ok, []}

      ids ->
        with {:ok, assignee_filter} <- routing_assignee_filter() do
          do_fetch_issue_states(ids, assignee_filter)
        end
    end
  end

  @spec graphql(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def graphql(query, variables \\ %{}, opts \\ [])
      when is_binary(query) and is_map(variables) and is_list(opts) do
    payload = build_graphql_payload(query, variables, Keyword.get(opts, :operation_name))
    request_fun = Keyword.get(opts, :request_fun, &post_graphql_request/2)
    sleep_fun = Keyword.get(opts, :sleep_fun, &Process.sleep/1)

    do_graphql(payload, request_fun, sleep_fun, 0)
  end

  @spec validate_auth() :: :ok | {:error, term()}
  def validate_auth do
    case graphql(@viewer_query, %{}, operation_name: "SymphonyLinearViewer") do
      {:ok, %{"data" => %{"viewer" => %{"id" => id}}}} when is_binary(id) ->
        :ok

      {:ok, %{"errors" => errors}} when is_list(errors) ->
        {:error, {:linear_graphql_errors, errors}}

      {:ok, _body} ->
        {:error, :missing_linear_viewer_identity}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec auth_failure?(term()) :: boolean()
  def auth_failure?(:missing_linear_api_token), do: true
  def auth_failure?({:linear_api_status, status}) when status in [401, 403], do: true

  def auth_failure?({:linear_graphql_errors, errors}) when is_list(errors) do
    Enum.any?(errors, &auth_graphql_error?/1)
  end

  def auth_failure?(_reason), do: false

  # A single Linear API key is shared by every daemon; the combined load hits
  # Linear's rate limit, which returns RATELIMITED. Treating it as a hard error
  # makes polling/reconciliation fail spuriously. Back off and retry a bounded
  # number of times so transient throttling degrades gracefully instead of
  # failing the operation.
  @rate_limit_max_retries 4
  @rate_limit_base_backoff_ms 2_000

  defp do_graphql(payload, request_fun, sleep_fun, attempt) do
    case graphql_headers() do
      {:ok, token, headers} ->
        do_graphql_with_headers(payload, request_fun, sleep_fun, attempt, token, headers)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_graphql_with_headers(payload, request_fun, sleep_fun, attempt, token, headers) do
    request_fun.(payload, headers)
    |> handle_graphql_result(payload, request_fun, sleep_fun, attempt, token)
  end

  defp handle_graphql_result({:ok, %{status: 200, body: body}}, payload, request_fun, sleep_fun, attempt, _token) do
    maybe_retry_rate_limited_body(body, payload, request_fun, sleep_fun, attempt)
  end

  defp handle_graphql_result(
         {:ok, %{status: status} = response},
         payload,
         request_fun,
         sleep_fun,
         attempt,
         token
       )
       when status in [401, 403] do
    maybe_retry_with_fallback_auth(payload, request_fun, sleep_fun, attempt, token, response)
  end

  defp handle_graphql_result({:ok, %{status: status} = response}, payload, request_fun, sleep_fun, attempt, _token)
       when status in [429] do
    maybe_retry_status(payload, request_fun, sleep_fun, attempt, response)
  end

  defp handle_graphql_result({:ok, %{status: 400} = response}, payload, request_fun, sleep_fun, attempt, _token) do
    maybe_retry_rate_limited_response(response, payload, request_fun, sleep_fun, attempt)
  end

  defp handle_graphql_result({:ok, response}, payload, _request_fun, _sleep_fun, _attempt, _token) do
    log_and_fail(payload, response)
  end

  defp handle_graphql_result({:error, reason}, _payload, _request_fun, _sleep_fun, _attempt, _token) do
    Logger.error("Linear GraphQL request failed: #{inspect(reason)}")
    {:error, {:linear_api_request, reason}}
  end

  defp maybe_retry_rate_limited_body(body, payload, request_fun, sleep_fun, attempt) do
    if rate_limited_body?(body) and attempt < @rate_limit_max_retries do
      backoff_and_retry(payload, request_fun, sleep_fun, attempt)
    else
      {:ok, body}
    end
  end

  defp maybe_retry_rate_limited_response(response, payload, request_fun, sleep_fun, attempt) do
    if rate_limited_body?(response.body) and attempt < @rate_limit_max_retries do
      backoff_and_retry(payload, request_fun, sleep_fun, attempt)
    else
      log_and_fail(payload, response)
    end
  end

  defp maybe_retry_status(payload, request_fun, sleep_fun, attempt, response) do
    if attempt < @rate_limit_max_retries do
      backoff_and_retry(payload, request_fun, sleep_fun, attempt)
    else
      log_and_fail(payload, response)
    end
  end

  defp maybe_retry_with_fallback_auth(payload, request_fun, sleep_fun, attempt, token, response) do
    case Auth.fallback_api_key(token) do
      {:ok, fallback_token} ->
        Logger.warning("Linear auth failed; retrying request with bootstrap Linear auth")
        retry_with_token(payload, request_fun, sleep_fun, attempt, fallback_token)

      :none ->
        log_and_fail(payload, response)
    end
  end

  defp retry_with_token(payload, request_fun, sleep_fun, attempt, token) do
    request_fun.(payload, graphql_headers_for_token(token))
    |> handle_fallback_graphql_result(payload, request_fun, sleep_fun, attempt, token)
  end

  defp handle_fallback_graphql_result({:ok, %{status: 200, body: body}}, payload, request_fun, sleep_fun, attempt, token) do
    Auth.put_runtime_api_key_override(token)
    maybe_retry_rate_limited_body(body, payload, request_fun, sleep_fun, attempt)
  end

  defp handle_fallback_graphql_result(
         {:ok, %{status: status} = response},
         payload,
         request_fun,
         sleep_fun,
         attempt,
         token
       )
       when status in [429] do
    Auth.put_runtime_api_key_override(token)
    maybe_retry_status(payload, request_fun, sleep_fun, attempt, response)
  end

  defp handle_fallback_graphql_result({:ok, response}, payload, _request_fun, _sleep_fun, _attempt, _token) do
    log_and_fail(payload, response)
  end

  defp handle_fallback_graphql_result({:error, reason}, _payload, _request_fun, _sleep_fun, _attempt, _token) do
    Logger.error("Linear GraphQL request failed: #{inspect(reason)}")
    {:error, {:linear_api_request, reason}}
  end

  defp backoff_and_retry(payload, request_fun, sleep_fun, attempt) do
    delay = @rate_limit_base_backoff_ms * Integer.pow(2, attempt)
    Logger.warning("Linear rate-limited; backing off #{delay}ms (attempt #{attempt + 1}/#{@rate_limit_max_retries})")
    sleep_fun.(delay)
    do_graphql(payload, request_fun, sleep_fun, attempt + 1)
  end

  defp rate_limited_body?(%{"errors" => errors}) when is_list(errors) do
    Enum.any?(errors, fn err -> get_in(err, ["extensions", "code"]) == "RATELIMITED" end)
  end

  defp rate_limited_body?(_body), do: false

  defp log_and_fail(payload, response) do
    Logger.error(
      "Linear GraphQL request failed status=#{response.status}" <>
        linear_error_context(payload, response)
    )

    {:error, {:linear_api_status, response.status}}
  end

  @doc false
  @spec normalize_issue_for_test(map()) :: Issue.t() | nil
  def normalize_issue_for_test(issue) when is_map(issue) do
    normalize_issue(issue, nil)
  end

  @doc false
  @spec normalize_issue_for_test(map(), String.t() | nil) :: Issue.t() | nil
  def normalize_issue_for_test(issue, assignee) when is_map(issue) do
    assignee_filter =
      case assignee do
        value when is_binary(value) ->
          case build_assignee_filter(value) do
            {:ok, filter} -> filter
            {:error, _reason} -> nil
          end

        _ ->
          nil
      end

    normalize_issue(issue, assignee_filter)
  end

  @doc false
  @spec next_page_cursor_for_test(map()) :: {:ok, String.t()} | :done | {:error, term()}
  def next_page_cursor_for_test(page_info) when is_map(page_info), do: next_page_cursor(page_info)

  @doc false
  @spec merge_issue_pages_for_test([[Issue.t()]]) :: [Issue.t()]
  def merge_issue_pages_for_test(issue_pages) when is_list(issue_pages) do
    issue_pages
    |> Enum.reduce([], &prepend_page_issues/2)
    |> finalize_paginated_issues()
  end

  @doc false
  @spec fetch_issue_states_by_ids_for_test([String.t()], (String.t(), map() -> {:ok, map()} | {:error, term()})) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids_for_test(issue_ids, graphql_fun)
      when is_list(issue_ids) and is_function(graphql_fun, 2) do
    ids = Enum.uniq(issue_ids)

    case ids do
      [] ->
        {:ok, []}

      ids ->
        do_fetch_issue_states(ids, nil, graphql_fun)
    end
  end

  defp do_fetch_by_states(project_slug, state_names, assignee_filter) do
    do_fetch_by_states_page(project_slug, state_names, assignee_filter, nil, [])
  end

  defp do_fetch_by_states_page(project_slug, state_names, assignee_filter, after_cursor, acc_issues) do
    with {:ok, body} <-
           graphql(@query, %{
             projectSlug: project_slug,
             stateNames: state_names,
             first: @issue_page_size,
             relationFirst: @issue_page_size,
             after: after_cursor
           }),
         {:ok, issues, page_info} <- decode_linear_page_response(body, assignee_filter) do
      updated_acc = prepend_page_issues(issues, acc_issues)

      case next_page_cursor(page_info) do
        {:ok, next_cursor} ->
          do_fetch_by_states_page(project_slug, state_names, assignee_filter, next_cursor, updated_acc)

        :done ->
          {:ok, finalize_paginated_issues(updated_acc)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp prepend_page_issues(issues, acc_issues) when is_list(issues) and is_list(acc_issues) do
    Enum.reverse(issues, acc_issues)
  end

  defp finalize_paginated_issues(acc_issues) when is_list(acc_issues), do: Enum.reverse(acc_issues)

  defp do_fetch_issue_states(ids, assignee_filter) do
    do_fetch_issue_states(ids, assignee_filter, &graphql/2)
  end

  defp do_fetch_issue_states(ids, assignee_filter, graphql_fun)
       when is_list(ids) and is_function(graphql_fun, 2) do
    issue_order_index = issue_order_index(ids)
    do_fetch_issue_states_page(ids, assignee_filter, graphql_fun, [], issue_order_index)
  end

  defp do_fetch_issue_states_page([], _assignee_filter, _graphql_fun, acc_issues, issue_order_index) do
    acc_issues
    |> finalize_paginated_issues()
    |> sort_issues_by_requested_ids(issue_order_index)
    |> then(&{:ok, &1})
  end

  defp do_fetch_issue_states_page(ids, assignee_filter, graphql_fun, acc_issues, issue_order_index) do
    {batch_ids, rest_ids} = Enum.split(ids, @issue_page_size)

    case graphql_fun.(@query_by_ids, %{
           ids: batch_ids,
           first: length(batch_ids),
           relationFirst: @issue_page_size
         }) do
      {:ok, body} ->
        with {:ok, issues} <- decode_linear_response(body, assignee_filter) do
          updated_acc = prepend_page_issues(issues, acc_issues)
          do_fetch_issue_states_page(rest_ids, assignee_filter, graphql_fun, updated_acc, issue_order_index)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp issue_order_index(ids) when is_list(ids) do
    ids
    |> Enum.with_index()
    |> Map.new()
  end

  defp sort_issues_by_requested_ids(issues, issue_order_index)
       when is_list(issues) and is_map(issue_order_index) do
    fallback_index = map_size(issue_order_index)

    Enum.sort_by(issues, fn
      %Issue{id: issue_id} -> Map.get(issue_order_index, issue_id, fallback_index)
      _ -> fallback_index
    end)
  end

  defp build_graphql_payload(query, variables, operation_name) do
    %{
      "query" => query,
      "variables" => variables
    }
    |> maybe_put_operation_name(operation_name)
  end

  defp maybe_put_operation_name(payload, operation_name) when is_binary(operation_name) do
    trimmed = String.trim(operation_name)

    if trimmed == "" do
      payload
    else
      Map.put(payload, "operationName", trimmed)
    end
  end

  defp maybe_put_operation_name(payload, _operation_name), do: payload

  defp linear_error_context(payload, response) when is_map(payload) do
    operation_name =
      case Map.get(payload, "operationName") do
        name when is_binary(name) and name != "" -> " operation=#{name}"
        _ -> ""
      end

    body =
      response
      |> Map.get(:body)
      |> summarize_error_body()

    operation_name <> " body=" <> body
  end

  defp summarize_error_body(body) when is_binary(body) do
    body
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate_error_body()
    |> inspect()
  end

  defp summarize_error_body(body) do
    body
    |> inspect(limit: 20, printable_limit: @max_error_body_log_bytes)
    |> truncate_error_body()
  end

  defp truncate_error_body(body) when is_binary(body) do
    if byte_size(body) > @max_error_body_log_bytes do
      binary_part(body, 0, @max_error_body_log_bytes) <> "...<truncated>"
    else
      body
    end
  end

  defp graphql_headers do
    case Auth.runtime_api_key_override() || Auth.resolve_api_key(Config.settings!().tracker.api_key) do
      {:error, :missing_linear_api_token} ->
        {:error, :missing_linear_api_token}

      token when is_binary(token) ->
        {:ok, token, graphql_headers_for_token(token)}

      {:ok, token} ->
        {:ok, token, graphql_headers_for_token(token)}
    end
  end

  defp graphql_headers_for_token(token) when is_binary(token) do
    [
      {"Authorization", token},
      {"Content-Type", "application/json"}
    ]
  end

  defp auth_configured?(configured_token) do
    case Auth.resolve_api_key(configured_token) do
      {:ok, _token} -> true
      {:error, :missing_linear_api_token} -> false
    end
  end

  defp auth_graphql_error?(%{"extensions" => %{"code" => code}}) when is_binary(code) do
    code in ["AUTHENTICATION_ERROR", "UNAUTHENTICATED"]
  end

  defp auth_graphql_error?(_error), do: false

  defp post_graphql_request(payload, headers) do
    Req.post(Config.settings!().tracker.endpoint,
      headers: headers,
      json: payload,
      connect_options: [timeout: 30_000]
    )
  end

  defp decode_linear_response(%{"data" => %{"issues" => %{"nodes" => nodes}}}, assignee_filter) do
    issues =
      nodes
      |> Enum.map(&normalize_issue(&1, assignee_filter))
      |> Enum.reject(&is_nil(&1))

    {:ok, issues}
  end

  defp decode_linear_response(%{"errors" => errors}, _assignee_filter) do
    {:error, {:linear_graphql_errors, errors}}
  end

  defp decode_linear_response(_unknown, _assignee_filter) do
    {:error, :linear_unknown_payload}
  end

  defp decode_linear_page_response(
         %{
           "data" => %{
             "issues" => %{
               "nodes" => nodes,
               "pageInfo" => %{"hasNextPage" => has_next_page, "endCursor" => end_cursor}
             }
           }
         },
         assignee_filter
       ) do
    with {:ok, issues} <- decode_linear_response(%{"data" => %{"issues" => %{"nodes" => nodes}}}, assignee_filter) do
      {:ok, issues, %{has_next_page: has_next_page == true, end_cursor: end_cursor}}
    end
  end

  defp decode_linear_page_response(response, assignee_filter), do: decode_linear_response(response, assignee_filter)

  defp next_page_cursor(%{has_next_page: true, end_cursor: end_cursor})
       when is_binary(end_cursor) and byte_size(end_cursor) > 0 do
    {:ok, end_cursor}
  end

  defp next_page_cursor(%{has_next_page: true}), do: {:error, :linear_missing_end_cursor}
  defp next_page_cursor(_), do: :done

  defp normalize_issue(issue, assignee_filter) when is_map(issue) do
    assignee = issue["assignee"]

    %Issue{
      id: issue["id"],
      identifier: issue["identifier"],
      title: issue["title"],
      description: issue["description"],
      priority: parse_priority(issue["priority"]),
      state: get_in(issue, ["state", "name"]),
      branch_name: issue["branchName"],
      url: issue["url"],
      assignee_id: assignee_field(assignee, "id"),
      blocked_by: extract_blockers(issue),
      labels: extract_labels(issue),
      assigned_to_worker: assigned_to_worker?(assignee, assignee_filter),
      created_at: parse_datetime(issue["createdAt"]),
      updated_at: parse_datetime(issue["updatedAt"])
    }
  end

  defp normalize_issue(_issue, _assignee_filter), do: nil

  defp assignee_field(%{} = assignee, field) when is_binary(field), do: assignee[field]
  defp assignee_field(_assignee, _field), do: nil

  defp assigned_to_worker?(_assignee, nil), do: true

  defp assigned_to_worker?(%{} = assignee, %{match_values: match_values})
       when is_struct(match_values, MapSet) do
    assignee
    |> assignee_id()
    |> then(fn
      nil -> false
      assignee_id -> MapSet.member?(match_values, assignee_id)
    end)
  end

  defp assigned_to_worker?(_assignee, _assignee_filter), do: false

  defp assignee_id(%{} = assignee), do: normalize_assignee_match_value(assignee["id"])

  defp routing_assignee_filter do
    case Config.settings!().tracker.assignee do
      nil ->
        {:ok, nil}

      assignee ->
        build_assignee_filter(assignee)
    end
  end

  defp build_assignee_filter(assignee) when is_binary(assignee) do
    case normalize_assignee_match_value(assignee) do
      nil ->
        {:ok, nil}

      "me" ->
        resolve_viewer_assignee_filter()

      normalized ->
        {:ok, %{configured_assignee: assignee, match_values: MapSet.new([normalized])}}
    end
  end

  defp resolve_viewer_assignee_filter do
    case graphql(@viewer_query, %{}) do
      {:ok, %{"data" => %{"viewer" => viewer}}} when is_map(viewer) ->
        case assignee_id(viewer) do
          nil ->
            {:error, :missing_linear_viewer_identity}

          viewer_id ->
            {:ok, %{configured_assignee: "me", match_values: MapSet.new([viewer_id])}}
        end

      {:ok, _body} ->
        {:error, :missing_linear_viewer_identity}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_assignee_match_value(value) when is_binary(value) do
    case value |> String.trim() do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_assignee_match_value(_value), do: nil

  defp extract_labels(%{"labels" => %{"nodes" => labels}}) when is_list(labels) do
    labels
    |> Enum.map(& &1["name"])
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&String.downcase/1)
  end

  defp extract_labels(_), do: []

  defp extract_blockers(%{"inverseRelations" => %{"nodes" => inverse_relations}})
       when is_list(inverse_relations) do
    inverse_relations
    |> Enum.flat_map(fn
      %{"type" => relation_type, "issue" => blocker_issue}
      when is_binary(relation_type) and is_map(blocker_issue) ->
        if String.downcase(String.trim(relation_type)) == "blocks" do
          [
            %{
              id: blocker_issue["id"],
              identifier: blocker_issue["identifier"],
              state: get_in(blocker_issue, ["state", "name"])
            }
          ]
        else
          []
        end

      _ ->
        []
    end)
  end

  defp extract_blockers(_), do: []

  defp parse_datetime(nil), do: nil

  defp parse_datetime(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_priority(priority) when is_integer(priority), do: priority
  defp parse_priority(_priority), do: nil
end
