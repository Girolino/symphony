defmodule SymphonyElixir.Linear.Client do
  @moduledoc """
  Thin Linear GraphQL client for polling candidate issues.
  """

  require Logger
  alias SymphonyElixir.{Config, OpsIssue}
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

    with :ok <- prevent_test_live_linear_mutation(payload, opts) do
      do_graphql(payload, request_fun, sleep_fun, %{attempt: 0, spent_ms: 0})
    end
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
  #
  # Bounds are deliberately small: the goal is to reduce QPS against Linear while
  # it is throttling us, not to amplify it. This is the ONLY retry layer in the
  # stack:
  #   - Req is called with `retry: false` (post_graphql_request/2) so it adds no
  #     attempts of its own.
  #   - Callers (AgentRunner turn boundary, orchestrator poll loop) must not wrap
  #     this in a second retry loop; layered loops multiply attempts and blocking
  #     time against an API that is already throttling us.
  # @retry_total_budget_ms is enforced (not decorative): cumulative slept time is
  # threaded through the retry state and retrying stops once the budget is spent,
  # so worst-case added latency per graphql/3 call stays under it.
  @rate_limit_max_retries 3
  @rate_limit_base_backoff_ms 2_000
  @rate_limit_max_backoff_ms 8_000
  @retry_total_budget_ms 15_000
  # Jitter on a server hint only needs to decorrelate concurrent daemons, not to
  # reshape the delay; the exponential ladder uses equal jitter instead (see
  # retry_delay_ms/2).
  @retry_hint_jitter_ms 1_000

  # Transport failures Linear/Req surface for a dropped or timed-out connection.
  # These are safe to retry; anything else (TLS/DNS/config errors) is not.
  @retryable_transport_reasons [:closed, :timeout, :econnreset, :econnrefused, :ehostunreach]

  defp do_graphql(payload, request_fun, sleep_fun, retry) do
    case graphql_headers() do
      {:ok, token, headers} ->
        do_graphql_with_headers(payload, request_fun, sleep_fun, retry, token, headers)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_graphql_with_headers(payload, request_fun, sleep_fun, retry, token, headers) do
    request_fun.(payload, headers)
    |> handle_graphql_result(payload, request_fun, sleep_fun, retry, token)
  end

  defp handle_graphql_result({:ok, %{status: 200, body: body} = response}, payload, request_fun, sleep_fun, retry, token) do
    if auth_error_body?(body) do
      maybe_retry_with_fallback_auth(payload, request_fun, sleep_fun, retry, token, response)
    else
      maybe_retry_rate_limited_body(body, payload, request_fun, sleep_fun, retry, response)
    end
  end

  defp handle_graphql_result(
         {:ok, %{status: status} = response},
         payload,
         request_fun,
         sleep_fun,
         retry,
         token
       )
       when status in [401, 403] do
    maybe_retry_with_fallback_auth(payload, request_fun, sleep_fun, retry, token, response)
  end

  defp handle_graphql_result({:ok, %{status: status} = response}, payload, request_fun, sleep_fun, retry, _token)
       when status in [429] do
    maybe_retry_status(payload, request_fun, sleep_fun, retry, response)
  end

  defp handle_graphql_result({:ok, %{status: 400} = response}, payload, request_fun, sleep_fun, retry, _token) do
    maybe_retry_rate_limited_response(response, payload, request_fun, sleep_fun, retry)
  end

  defp handle_graphql_result({:ok, response}, payload, _request_fun, _sleep_fun, _attempt, _token) do
    log_and_fail(payload, response)
  end

  # A dropped/timed-out POST may well have been applied server-side before the
  # response was lost, so replaying it can duplicate a write (commentCreate,
  # issueUpdate, issueCreate, or anything an agent sends through the raw
  # linear_graphql tool). This is exactly why Req's default `retry:
  # :safe_transient` only retries GET/HEAD. Retry transport failures for read
  # documents only; mutations fail through on the first transport error as before.
  defp handle_graphql_result({:error, reason}, payload, request_fun, sleep_fun, retry, _token) do
    if retryable_transport_error?(reason) and idempotent_payload?(payload) do
      case retry_decision(retry, nil) do
        {:retry, delay} ->
          Logger.warning("Linear GraphQL transport error #{inspect(reason)}; retrying")
          backoff_and_retry(payload, request_fun, sleep_fun, retry, delay, nil)

        :exhausted ->
          Logger.error("Linear GraphQL request failed: #{inspect(reason)}")
          {:error, {:linear_api_request, reason}}
      end
    else
      Logger.error("Linear GraphQL request failed: #{inspect(reason)}")
      {:error, {:linear_api_request, reason}}
    end
  end

  # Keep the whole response: the Retry-After hint lives in the HTTP headers even
  # when Linear reports the throttle as a 200 with a RATELIMITED error body, so
  # rebuilding a synthetic %{status: 200, body: body} here would silently discard
  # the server hint on Linear's most common rate-limit shape.
  defp maybe_retry_rate_limited_body(body, payload, request_fun, sleep_fun, retry, response) do
    if rate_limited_body?(body) do
      retry_rate_limited(payload, request_fun, sleep_fun, retry, response)
    else
      {:ok, body}
    end
  end

  defp maybe_retry_rate_limited_response(response, payload, request_fun, sleep_fun, retry) do
    if rate_limited_body?(response.body) do
      retry_rate_limited(payload, request_fun, sleep_fun, retry, response)
    else
      log_and_fail(payload, response)
    end
  end

  defp maybe_retry_status(payload, request_fun, sleep_fun, retry, response) do
    retry_rate_limited(payload, request_fun, sleep_fun, retry, response)
  end

  # A rate-limited request was rejected, never applied, so replaying it is safe
  # for mutations too.
  defp retry_rate_limited(payload, request_fun, sleep_fun, retry, response) do
    hint = retry_after_ms(response)

    case retry_decision(retry, hint) do
      {:retry, delay} ->
        backoff_and_retry(payload, request_fun, sleep_fun, retry, delay, hint)

      :exhausted ->
        rate_limited_error(payload, response)
    end
  end

  # Single place that decides whether another attempt is allowed. Three bounds,
  # all of them load-bearing:
  #   1. attempt count (@rate_limit_max_retries),
  #   2. a server hint longer than we are willing to hold the caller for - if
  #      Linear says the window is 60s, retrying at 8s is a guaranteed-doomed
  #      request, so stop and let the caller reconcile later,
  #   3. the cumulative backoff budget (@retry_total_budget_ms).
  defp retry_decision(%{attempt: attempt, spent_ms: spent_ms}, retry_after_ms) do
    delay = retry_delay_ms(attempt, retry_after_ms)

    cond do
      attempt >= @rate_limit_max_retries -> :exhausted
      is_integer(retry_after_ms) and retry_after_ms > @rate_limit_max_backoff_ms -> :exhausted
      spent_ms + delay > @retry_total_budget_ms -> :exhausted
      true -> {:retry, delay}
    end
  end

  @doc false
  @spec idempotent_payload?(map()) :: boolean()
  def idempotent_payload?(%{"query" => document}) when is_binary(document) do
    not Regex.match?(~r/\bmutation\b/i, document)
  end

  def idempotent_payload?(_payload), do: false

  if Mix.env() == :test do
    defp prevent_test_live_linear_mutation(payload, opts) do
      cond do
        Keyword.has_key?(opts, :request_fun) -> :ok
        idempotent_payload?(payload) -> :ok
        true -> {:error, :test_live_linear_mutation_disabled}
      end
    end
  else
    defp prevent_test_live_linear_mutation(_payload, _opts), do: :ok
  end

  # Distinct, adapter-owned rate-limit category (SPEC 11.4). Callers that only
  # match {:linear_api_status, _} keep working through their catch-all clauses,
  # while retry-aware callers (AgentRunner turn boundary) can honor retry_after_ms.
  defp rate_limited_error(payload, response) do
    status = Map.get(response, :status)

    Logger.error(
      "Linear GraphQL request rate limited after #{@rate_limit_max_retries} retries status=#{status}" <>
        linear_error_context(payload, response)
    )

    {:error, {:tracker_rate_limited, %{status: status, retry_after_ms: retry_after_ms(response)}}}
  end

  @doc false
  @spec retryable_transport_error?(term()) :: boolean()
  def retryable_transport_error?(%{__struct__: Req.TransportError, reason: reason}),
    do: reason in @retryable_transport_reasons

  def retryable_transport_error?(%{__struct__: Mint.TransportError, reason: reason}),
    do: reason in @retryable_transport_reasons

  def retryable_transport_error?(_reason), do: false

  @doc false
  @spec retry_after_ms(map()) :: pos_integer() | nil
  def retry_after_ms(response) when is_map(response) do
    header_retry_after_ms(Map.get(response, :headers)) || body_retry_after_ms(Map.get(response, :body))
  end

  defp header_retry_after_ms(headers) when is_map(headers) do
    headers
    |> Enum.find_value(fn {name, value} ->
      if String.downcase(to_string(name)) == "retry-after", do: value
    end)
    |> seconds_header_to_ms()
  end

  defp header_retry_after_ms(headers) when is_list(headers) do
    header_retry_after_ms(Map.new(headers))
  end

  defp header_retry_after_ms(_headers), do: nil

  defp seconds_header_to_ms([value | _]), do: seconds_header_to_ms(value)

  defp seconds_header_to_ms(value) when is_binary(value) do
    case Float.parse(value) do
      {seconds, _rest} when seconds > 0 -> round(seconds * 1_000)
      _ -> nil
    end
  end

  defp seconds_header_to_ms(value) when is_integer(value) and value > 0, do: value * 1_000
  defp seconds_header_to_ms(_value), do: nil

  defp body_retry_after_ms(%{"errors" => errors}) when is_list(errors) do
    Enum.find_value(errors, fn error ->
      extensions = get_in(error, ["extensions"]) || %{}

      cond do
        is_integer(extensions["retryAfterMs"]) and extensions["retryAfterMs"] > 0 -> extensions["retryAfterMs"]
        is_number(extensions["retryAfter"]) and extensions["retryAfter"] > 0 -> round(extensions["retryAfter"] * 1_000)
        true -> nil
      end
    end)
  end

  defp body_retry_after_ms(_body), do: nil

  defp maybe_retry_with_fallback_auth(payload, request_fun, sleep_fun, retry, token, response) do
    case Auth.fallback_api_key(token) do
      {:ok, fallback_token} ->
        Logger.warning("Linear auth failed; retrying request with bootstrap Linear auth")
        retry_with_token(payload, request_fun, sleep_fun, retry, fallback_token, token, response)

      :none ->
        Auth.clear_runtime_api_key_override()
        log_auth_and_fail(payload, response)
    end
  end

  defp retry_with_token(payload, request_fun, sleep_fun, retry, token, failed_token, failure_response) do
    request_fun.(payload, graphql_headers_for_token(token))
    |> handle_fallback_graphql_result(payload, request_fun, sleep_fun, retry, token, failed_token, failure_response)
  end

  defp handle_fallback_graphql_result(
         {:ok, %{status: 200, body: body} = response},
         payload,
         request_fun,
         sleep_fun,
         retry,
         token,
         failed_token,
         failure_response
       ) do
    if auth_error_body?(body) do
      Auth.clear_runtime_api_key_override()
      log_auth_and_fail(payload, %{status: 200, body: body})
    else
      promote_fallback_token(token, failed_token, failure_response)
      maybe_retry_rate_limited_body(body, payload, request_fun, sleep_fun, retry, response)
    end
  end

  defp handle_fallback_graphql_result(
         {:ok, %{status: status} = response},
         payload,
         request_fun,
         sleep_fun,
         retry,
         token,
         failed_token,
         failure_response
       )
       when status in [429] do
    promote_fallback_token(token, failed_token, failure_response)
    maybe_retry_status(payload, request_fun, sleep_fun, retry, response)
  end

  defp handle_fallback_graphql_result({:ok, response}, payload, _request_fun, _sleep_fun, _attempt, _token, _failed_token, _failure_response) do
    Auth.clear_runtime_api_key_override()
    log_auth_and_fail(payload, response)
  end

  defp handle_fallback_graphql_result({:error, reason}, _payload, _request_fun, _sleep_fun, _attempt, _token, _failed_token, _failure_response) do
    Auth.clear_runtime_api_key_override()
    Logger.error("Linear GraphQL request failed: #{inspect(reason)}")
    {:error, {:linear_api_request, reason}}
  end

  defp backoff_and_retry(payload, request_fun, sleep_fun, %{attempt: attempt, spent_ms: spent_ms}, delay, retry_after_ms) do
    Logger.warning(
      "Linear request backing off #{delay}ms (retry #{attempt + 1}/#{@rate_limit_max_retries}, " <>
        "budget #{spent_ms + delay}/#{@retry_total_budget_ms}ms)" <>
        if(is_integer(retry_after_ms), do: " retry_after_ms=#{retry_after_ms}", else: "")
    )

    sleep_fun.(delay)
    do_graphql(payload, request_fun, sleep_fun, %{attempt: attempt + 1, spent_ms: spent_ms + delay})
  end

  @doc """
  Pure backoff computation for one retry: exponential ladder with equal jitter,
  or a server-provided retry-after hint plus a small jitter.

  Equal jitter (`base/2 + rand(base/2)`) rather than a narrow additive band: a
  single Linear API key is shared by every daemon, so when the throttle window
  resets they all get unblocked together. The delays have to spread far enough to
  actually decorrelate the burst, not land inside a 400ms window.

  This is a per-delay value only. The worst-case latency of a whole `graphql/3`
  call is bounded separately by `retry_decision/2`, which stops retrying once the
  cumulative slept time would exceed #{@retry_total_budget_ms}ms.
  """
  @spec retry_delay_ms(non_neg_integer(), pos_integer() | nil) :: pos_integer()
  def retry_delay_ms(attempt, retry_after_ms \\ nil) when is_integer(attempt) and attempt >= 0 do
    case retry_after_ms do
      ms when is_integer(ms) and ms > 0 ->
        min(ms, @rate_limit_max_backoff_ms) + :rand.uniform(@retry_hint_jitter_ms)

      _ ->
        base =
          @rate_limit_base_backoff_ms
          |> Kernel.*(Integer.pow(2, min(attempt, 16)))
          |> min(@rate_limit_max_backoff_ms)

        half = max(div(base, 2), 1)
        half + :rand.uniform(half)
    end
  end

  defp rate_limited_body?(%{"errors" => errors}) when is_list(errors) do
    Enum.any?(errors, fn err -> get_in(err, ["extensions", "code"]) == "RATELIMITED" end)
  end

  defp rate_limited_body?(_body), do: false

  defp log_and_fail(payload, response) do
    if Map.get(response, :status) in [401, 403] do
      Auth.clear_runtime_api_key_override()
    end

    Logger.error(
      "Linear GraphQL request failed status=#{response.status}" <>
        linear_error_context(payload, response)
    )

    {:error, {:linear_api_status, response.status}}
  end

  defp log_auth_and_fail(payload, %{status: 200, body: %{"errors" => errors}} = response)
       when is_list(errors) do
    Logger.error(
      "Linear GraphQL request failed authentication errors" <>
        linear_error_context(payload, response)
    )

    {:error, {:linear_graphql_errors, errors}}
  end

  defp log_auth_and_fail(payload, response), do: log_and_fail(payload, response)

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
    case Auth.resolve_api_key(Config.settings!().tracker.api_key) do
      {:error, :missing_linear_api_token} ->
        {:error, :missing_linear_api_token}

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

  defp auth_error_body?(%{"errors" => errors}) when is_list(errors), do: Enum.any?(errors, &auth_graphql_error?/1)
  defp auth_error_body?(_body), do: false

  defp promote_fallback_token(token, failed_token, failure_response) do
    Auth.put_runtime_api_key_override(token, failed_token)
    maybe_file_fallback_auth_ops_issue(failure_response)
  end

  defp maybe_file_fallback_auth_ops_issue(failure_response) do
    if Application.get_env(:symphony_elixir, :linear_auth_fallback_reported) == true do
      :ok
    else
      Application.put_env(:symphony_elixir, :linear_auth_fallback_reported, true)
      file_fallback_auth_ops_issue(failure_response)
    end
  end

  defp file_fallback_auth_ops_issue(failure_response) do
    Task.start(fn ->
      title = "daemon Linear primary auth fallback in use"

      body =
        "The Symphony daemon recovered a Linear request by using the documented bootstrap credential after the primary configured credential failed. " <>
          "Reason: #{inspect(primary_auth_failure_reason(failure_response))}. Rotate the configured Linear credential; daemon requests continue through fallback until primary auth recovers."

      case fallback_auth_ops_filer().file(title, body, []) do
        {:created, issue} ->
          Logger.warning("Linear auth fallback ops issue created: #{issue["identifier"]}")

        {:existing, issue} ->
          Logger.warning("Linear auth fallback ops issue already open: #{issue["identifier"]}")

        {:error, reason} ->
          Logger.error("Linear auth fallback ops issue filing failed: #{inspect(reason)}")
      end
    end)

    :ok
  end

  defp primary_auth_failure_reason(%{status: 200, body: %{"errors" => errors}}) when is_list(errors) do
    {:linear_graphql_errors, Enum.map(errors, &get_in(&1, ["extensions", "code"]))}
  end

  defp primary_auth_failure_reason(%{status: status}), do: {:linear_api_status, status}

  defp fallback_auth_ops_filer do
    Application.get_env(:symphony_elixir, :linear_auth_fallback_filer, OpsIssue)
  end

  # `retry: false` is explicit, matching Linear.OpsTransport: this module owns the
  # only retry layer (see @rate_limit_max_retries). Req's default
  # `retry: :safe_transient` happens to skip POST today, but relying on that
  # implicitly would make a future Req default silently multiply our attempts
  # against an API that is already throttling us.
  defp post_graphql_request(payload, headers) do
    Req.post(Config.settings!().tracker.endpoint,
      headers: headers,
      json: payload,
      retry: false,
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
