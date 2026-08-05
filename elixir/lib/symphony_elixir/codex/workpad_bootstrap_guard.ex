defmodule SymphonyElixir.Codex.WorkpadBootstrapGuard do
  @moduledoc """
  Serializes Codex workpad bootstrap comment creation through `linear_graphql`.

  Codex owns the workpad lifecycle through raw Linear GraphQL calls. When two
  sessions race after both have observed no active workpad, Linear offers no
  uniqueness constraint on comments, so the harness guards the specific
  `## Codex Workpad` create operation before it reaches Linear.
  """

  require Logger

  alias SymphonyElixir.Config

  @active_workpad_query """
  query SymphonyActiveWorkpadComments($issueId: String!) {
    issue(id: $issueId) {
      comments(first: 50) {
        nodes {
          id
          body
          resolvedAt
          createdAt
          updatedAt
          url
        }
      }
    }
  }
  """
  @resolve_duplicate_workpad_mutation """
  mutation SymphonyResolveDuplicateWorkpad($id: String!) {
    commentResolve(id: $id) {
      success
      comment {
        id
        resolvedAt
      }
    }
  }
  """
  @cached_workpad_comment_query """
  query SymphonyCachedWorkpadComment($id: String!) {
    comment(id: $id) {
      id
      body
      resolvedAt
      createdAt
      updatedAt
      url
    }
  }
  """

  @lock_timeout_ms 30_000
  @lock_stale_ms 60_000
  @recent_workpad_cache_ttl_ms 300_000
  @retry_sleep_ms 50
  @workpad_marker "## Codex Workpad"

  @type linear_client :: (String.t(), map(), keyword() -> {:ok, map()} | {:error, term()})
  @type lock :: %{
          path: Path.t(),
          token: String.t(),
          issue_id: String.t()
        }

  @spec execute(String.t(), map(), linear_client()) :: {:ok, map()} | {:error, term()}
  def execute(query, variables, linear_client)
      when is_binary(query) and is_map(variables) and is_function(linear_client, 3) do
    case workpad_create_input(query, variables) do
      {:ok, issue_id} ->
        with_issue_lock(issue_id, fn -> create_or_reuse_workpad(query, variables, linear_client, issue_id) end)

      :ignore ->
        linear_client.(query, variables, [])
    end
  end

  defp create_or_reuse_workpad(query, variables, linear_client, issue_id) do
    with {:ok, comments} <- fetch_workpad_comments(linear_client, issue_id) do
      create_or_reuse_workpad_from_comments(comments, query, variables, linear_client, issue_id)
    end
  end

  defp create_or_reuse_workpad_from_comments(comments, query, variables, linear_client, issue_id) do
    case Enum.filter(comments, &active_workpad_comment?/1) do
      [] -> reuse_cached_or_create_workpad(comments, query, variables, linear_client, issue_id)
      active_comments -> reuse_active_workpad(linear_client, issue_id, active_comments)
    end
  end

  defp reuse_cached_or_create_workpad(comments, query, variables, linear_client, issue_id) do
    case read_recent_workpad_cache(issue_id, comments, linear_client) do
      {:ok, comment} -> {:ok, reuse_response(comment, [])}
      {:error, reason} -> {:error, reason}
      :miss -> create_workpad(query, variables, linear_client, issue_id)
    end
  end

  defp reuse_active_workpad(linear_client, issue_id, active_comments) do
    canonical = newest_comment(active_comments)

    with {:ok, resolved_ids} <- resolve_duplicate_workpads(linear_client, active_comments, canonical) do
      write_recent_workpad_cache(issue_id, canonical)
      {:ok, reuse_response(canonical, resolved_ids)}
    end
  end

  defp create_workpad(query, variables, linear_client, issue_id) do
    with {:ok, response} <- linear_client.(query, variables, []) do
      case comment_create_success?(response) do
        true ->
          {:ok, maybe_attach_active_workpad(response, linear_client, issue_id)}

        false ->
          {:ok, response}
      end
    end
  end

  defp maybe_attach_active_workpad(response, linear_client, issue_id) do
    case fetch_workpad_comments(linear_client, issue_id) do
      {:ok, comments} ->
        maybe_attach_workpad_from_comments(response, linear_client, issue_id, comments)

      other ->
        Logger.warning(
          "Skipping workpad reconciliation after post-create lookup failure " <>
            "issue_id=#{issue_id} reason=#{inspect(other)}"
        )

        cache_created_workpad_from_response(response, issue_id)
    end
  end

  defp maybe_attach_workpad_from_comments(response, linear_client, issue_id, comments) do
    case Enum.filter(comments, &active_workpad_comment?/1) do
      [] -> cache_created_workpad_from_response(response, issue_id)
      active_comments -> attach_active_workpad(response, linear_client, issue_id, active_comments)
    end
  end

  defp attach_active_workpad(response, linear_client, issue_id, active_comments) do
    canonical = newest_comment(active_comments)

    case resolve_duplicate_workpads(linear_client, active_comments, canonical) do
      {:ok, resolved_ids} ->
        write_recent_workpad_cache(issue_id, canonical)
        put_comment_create(response, canonical, false, resolved_ids)

      {:error, _reason} ->
        response
    end
  end

  defp fetch_workpad_comments(linear_client, issue_id) do
    with {:ok, response} <- linear_client.(@active_workpad_query, %{"issueId" => issue_id}, []) do
      response
      |> comment_nodes()
      |> Enum.filter(&workpad_comment?/1)
      |> then(&{:ok, &1})
    end
  end

  defp workpad_create_input(query, variables) do
    if String.contains?(query, "commentCreate") do
      variables
      |> find_workpad_create_issue_id()
      |> maybe_find_inline_workpad_create_issue_id(query, variables)
    else
      :ignore
    end
  end

  defp workpad_body?(body) when is_binary(body) do
    body
    |> String.trim_leading()
    |> String.starts_with?(@workpad_marker)
  end

  defp workpad_body?(_body), do: false

  defp workpad_comment?(%{} = comment) do
    workpad_body?(map_get(comment, "body"))
  end

  defp workpad_comment?(_comment), do: false

  defp active_workpad_comment?(%{} = comment) do
    workpad_body?(map_get(comment, "body")) and is_nil(map_get(comment, "resolvedAt"))
  end

  defp newest_comment(comments) do
    Enum.max_by(comments, &comment_sort_key/1)
  end

  defp resolve_duplicate_workpads(linear_client, comments, canonical) do
    comments
    |> duplicate_comment_ids(canonical)
    |> Enum.reduce_while({:ok, []}, fn comment_id, {:ok, resolved_ids} ->
      case resolve_duplicate_workpad(linear_client, comment_id) do
        :ok -> {:cont, {:ok, [comment_id | resolved_ids]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, resolved_ids} -> {:ok, Enum.reverse(resolved_ids)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp duplicate_comment_ids(comments, canonical) do
    canonical_id = map_get(canonical, "id")

    comments
    |> Enum.map(&map_get(&1, "id"))
    |> Enum.filter(&(is_binary(&1) and &1 != canonical_id))
  end

  defp resolve_duplicate_workpad(linear_client, comment_id) do
    case linear_client.(@resolve_duplicate_workpad_mutation, %{"id" => comment_id}, []) do
      {:ok, response} ->
        if response |> map_get("data") |> map_get("commentResolve") |> map_get("success") == true do
          :ok
        else
          {:error, {:workpad_duplicate_resolve_failed, comment_id}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp comment_sort_key(comment) do
    map_get(comment, "updatedAt") || map_get(comment, "createdAt") || map_get(comment, "id") || ""
  end

  defp comment_nodes(response) do
    response
    |> map_get("data")
    |> map_get("issue")
    |> map_get("comments")
    |> map_get("nodes")
    |> case do
      nodes when is_list(nodes) -> nodes
      _ -> []
    end
  end

  defp comment_create_success?(response) do
    response
    |> map_get("data")
    |> map_get("commentCreate")
    |> map_get("success") == true
  end

  defp comment_create_comment(response) do
    response
    |> map_get("data")
    |> map_get("commentCreate")
    |> map_get("comment")
    |> case do
      %{} = comment -> comment
      _ -> nil
    end
  end

  defp reuse_response(comment, resolved_ids) do
    %{
      "data" => %{
        "commentCreate" => %{
          "success" => true,
          "comment" => comment,
          "reusedExistingWorkpad" => true,
          "resolvedDuplicateIds" => resolved_ids
        }
      }
    }
  end

  defp put_comment_create(response, comment, reused?, resolved_ids) when is_map(response) do
    data = map_get(response, "data") || %{}
    comment_create = map_get(data, "commentCreate") || %{}

    updated_comment_create =
      comment_create
      |> Map.put("success", true)
      |> Map.put("comment", comment)
      |> Map.put("reusedExistingWorkpad", reused?)
      |> Map.put("resolvedDuplicateIds", resolved_ids)

    response
    |> Map.put("data", Map.put(data, "commentCreate", updated_comment_create))
  end

  defp cache_created_workpad_from_response(response, issue_id) do
    case comment_create_comment(response) do
      %{} = comment ->
        write_recent_workpad_cache(issue_id, comment)
        put_comment_create(response, comment, false, [])

      nil ->
        response
    end
  end

  defp with_issue_lock(issue_id, fun) do
    path = lock_path(issue_id)
    started_at = monotonic_ms()

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, lock} <- acquire_lock(path, started_at, issue_id) do
      try do
        fun.()
      after
        release_lock(lock)
      end
    end
  rescue
    error in [ArgumentError, File.Error] ->
      {:error, error}
  end

  defp acquire_lock(path, started_at, issue_id) do
    case File.mkdir(path) do
      :ok ->
        token = lock_token()

        case write_lock_metadata(path, issue_id, token) do
          :ok ->
            {:ok, %{path: path, token: token, issue_id: issue_id}}

          {:error, reason} ->
            _ = remove_lock_path(path, issue_id, :metadata_failure)
            {:error, {:workpad_bootstrap_lock_metadata_failed, path, reason}}
        end

      {:error, :eexist} ->
        handle_existing_lock(path, started_at, issue_id)

      {:error, reason} ->
        {:error, {:workpad_bootstrap_lock_create_failed, path, reason}}
    end
  end

  defp handle_existing_lock(path, started_at, issue_id) do
    cond do
      lock_stale?(path) ->
        reclaim_and_reacquire_lock(path, started_at, issue_id)

      monotonic_ms() - started_at >= @lock_timeout_ms ->
        {:error, {:workpad_bootstrap_lock_timeout, path}}

      true ->
        Process.sleep(@retry_sleep_ms)
        acquire_lock(path, started_at, issue_id)
    end
  end

  defp reclaim_and_reacquire_lock(path, started_at, issue_id) do
    case reclaim_stale_lock(path, issue_id) do
      :ok -> acquire_lock(path, started_at, issue_id)
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_lock_metadata(path, issue_id, token) do
    metadata = %{
      token: token,
      issue_id: issue_id,
      owner_os_pid: System.pid(),
      owner_elixir_pid: self() |> :erlang.pid_to_list() |> List.to_string(),
      acquired_unix_ms: System.system_time(:millisecond)
    }

    try do
      with {:ok, encoded} <- Jason.encode(metadata),
           :ok <- write_lock_metadata_file(Path.join(path, "owner.json"), encoded) do
        :ok
      else
        {:error, reason} -> {:error, reason}
      end
    rescue
      error in [File.Error, Jason.EncodeError] -> {:error, error}
    end
  end

  defp reclaim_stale_lock(path, issue_id) do
    reclaimed_path = "#{path}.stale-#{System.unique_integer([:positive, :monotonic])}"

    case File.rename(path, reclaimed_path) do
      :ok ->
        Logger.warning("Reclaiming stale workpad bootstrap lock issue_id=#{issue_id} path=#{path}")
        remove_lock_path(reclaimed_path, issue_id, :stale_reclaim)

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, {:workpad_bootstrap_lock_reclaim_failed, path, reason}}
    end
  end

  defp release_lock(%{path: path, token: token, issue_id: issue_id}) do
    case read_lock_metadata(path) do
      {:ok, %{"token" => ^token}} ->
        remove_lock_path(path, issue_id, :release)

      {:ok, _metadata} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Skipping workpad bootstrap lock release after metadata read failure " <>
            "issue_id=#{issue_id} path=#{path} reason=#{inspect(reason)}"
        )

        :ok
    end
  end

  defp remove_lock_path(path, issue_id, reason_context) do
    case File.rm_rf(path) do
      {:ok, _removed} ->
        :ok

      {:error, reason, failed_path} ->
        Logger.error(
          "Failed to remove workpad bootstrap lock issue_id=#{issue_id} path=#{path} " <>
            "failed_path=#{failed_path} reason=#{inspect(reason)}"
        )

        {:error, {:workpad_bootstrap_lock_remove_failed, reason_context, failed_path, reason}}
    end
  end

  defp lock_stale?(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime}} when is_integer(mtime) ->
        System.system_time(:millisecond) - mtime * 1_000 > @lock_stale_ms

      _ ->
        false
    end
  end

  defp read_lock_metadata(path) do
    path
    |> Path.join("owner.json")
    |> File.read()
    |> case do
      {:ok, body} -> Jason.decode(body)
      {:error, :enoent} -> {:error, :missing_metadata}
      {:error, reason} -> {:error, reason}
    end
  end

  defp lock_path(issue_id) do
    Config.settings!().workspace.root
    |> Path.expand()
    |> Path.join(".symphony-workpad-bootstrap-locks")
    |> Path.join(safe_key(issue_id))
  end

  defp recent_workpad_cache_path(issue_id) do
    Config.settings!().workspace.root
    |> Path.expand()
    |> Path.join(".symphony-workpad-bootstrap-cache")
    |> Path.join("#{safe_key(issue_id)}.json")
  end

  defp read_recent_workpad_cache(issue_id, visible_comments, linear_client) do
    cache_path = recent_workpad_cache_path(issue_id)

    with {:ok, body} <- File.read(cache_path),
         {:ok, cache} <- Jason.decode(body),
         true <- recent_workpad_cache_fresh?(cache),
         %{} = comment <- map_get(cache, "comment"),
         true <- cached_workpad_comment_shape?(comment) do
      validate_recent_workpad_cache(cache_path, issue_id, comment, visible_comments, linear_client)
    else
      {:error, :enoent} ->
        :miss

      {:error, %Jason.DecodeError{}} ->
        remove_recent_workpad_cache(cache_path)
        :miss

      {:error, _reason} ->
        :miss

      false ->
        remove_recent_workpad_cache(cache_path)
        :miss

      _ ->
        remove_recent_workpad_cache(cache_path)
        :miss
    end
  rescue
    _error in [ArgumentError, File.Error] -> :miss
  end

  defp validate_recent_workpad_cache(cache_path, issue_id, comment, visible_comments, linear_client) do
    comment_id = map_get(comment, "id")

    case Enum.find(visible_comments, &(map_get(&1, "id") == comment_id)) do
      %{} ->
        remove_recent_workpad_cache(cache_path)
        :miss

      nil ->
        verify_cached_workpad_comment(cache_path, issue_id, comment_id, linear_client)
    end
  end

  defp verify_cached_workpad_comment(cache_path, issue_id, comment_id, linear_client) do
    case fetch_workpad_comment(linear_client, comment_id) do
      {:ok, %{} = comment} ->
        if active_workpad_comment?(comment) do
          {:ok, comment}
        else
          remove_recent_workpad_cache(cache_path)
          :miss
        end

      {:ok, nil} ->
        remove_recent_workpad_cache(cache_path)
        :miss

      {:error, reason} ->
        Logger.warning(
          "Failing closed after cached workpad lookup failure " <>
            "issue_id=#{issue_id} comment_id=#{comment_id} reason=#{inspect(reason)}"
        )

        {:error, {:cached_workpad_comment_lookup_failed, comment_id, reason}}
    end
  end

  defp fetch_workpad_comment(linear_client, comment_id) when is_binary(comment_id) do
    with {:ok, response} <- linear_client.(@cached_workpad_comment_query, %{"id" => comment_id}, []) do
      {:ok, response |> map_get("data") |> map_get("comment")}
    end
  end

  defp write_recent_workpad_cache(issue_id, comment) when is_map(comment) do
    payload_comment = recent_workpad_cache_comment(comment)

    if cached_workpad_comment_shape?(payload_comment) do
      cache_path = recent_workpad_cache_path(issue_id)

      payload = %{
        comment: payload_comment,
        issue_id: issue_id,
        cached_unix_ms: System.system_time(:millisecond)
      }

      with :ok <- File.mkdir_p(Path.dirname(cache_path)),
           {:ok, encoded} <- Jason.encode(payload),
           :ok <- File.write(cache_path, encoded) do
        :ok
      else
        _ -> :ok
      end
    else
      :ok
    end
  rescue
    _error in [ArgumentError, File.Error, Jason.EncodeError] -> :ok
  end

  defp recent_workpad_cache_fresh?(cache) do
    case map_get(cache, "cached_unix_ms") do
      cached_unix_ms when is_integer(cached_unix_ms) ->
        System.system_time(:millisecond) - cached_unix_ms <= @recent_workpad_cache_ttl_ms

      _ ->
        false
    end
  end

  defp cached_workpad_comment_shape?(comment) do
    is_map(comment) and is_binary(map_get(comment, "id")) and workpad_body?(map_get(comment, "body"))
  end

  defp recent_workpad_cache_comment(comment) do
    ["id", "body", "resolvedAt", "createdAt", "updatedAt", "url"]
    |> Enum.reduce(%{}, fn key, acc ->
      case map_get(comment, key) do
        nil -> acc
        value -> Map.put(acc, key, value)
      end
    end)
  end

  defp remove_recent_workpad_cache(cache_path) do
    _ = File.rm(cache_path)
    :ok
  end

  defp safe_key(value) when is_binary(value) do
    String.replace(value, ~r/[^a-zA-Z0-9_-]/, "_")
  end

  defp map_get(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) || Map.get(map, String.to_atom(key))
  end

  defp map_get(_map, _key), do: nil

  defp find_workpad_create_issue_id(value) when is_map(value) do
    case workpad_issue_id_from_input(value) do
      {:ok, _issue_id} = result ->
        result

      :ignore ->
        find_nested_workpad_create_issue_id(value)
    end
  end

  defp find_workpad_create_issue_id(_value), do: :ignore

  defp find_nested_workpad_create_issue_id(value) do
    value
    |> Map.values()
    |> Enum.find_value(&workpad_create_issue_id_or_nil/1) || :ignore
  end

  defp workpad_create_issue_id_or_nil(value) do
    case find_workpad_create_issue_id(value) do
      {:ok, _issue_id} = result -> result
      :ignore -> nil
    end
  end

  defp maybe_find_inline_workpad_create_issue_id({:ok, _issue_id} = result, _query, _variables), do: result
  defp maybe_find_inline_workpad_create_issue_id(:ignore, query, variables), do: find_inline_workpad_create_issue_id(query, variables)

  defp find_inline_workpad_create_issue_id(query, variables) do
    with {:ok, after_create} <- after_first_match(query, "commentCreate"),
         true <- inline_input_argument?(after_create),
         {:ok, body} <- inline_graphql_field(after_create, "body", variables),
         true <- workpad_body?(body),
         {:ok, issue_id} <- inline_graphql_field(after_create, "issueId", variables),
         true <- issue_id != "" do
      {:ok, issue_id}
    else
      _ -> :ignore
    end
  end

  defp after_first_match(value, match) do
    case :binary.match(value, match) do
      {index, match_size} ->
        start = index + match_size
        {:ok, binary_part(value, start, byte_size(value) - start)}

      :nomatch ->
        :error
    end
  end

  defp inline_input_argument?(value) do
    Regex.match?(~r/^\s*\(\s*input\s*:/s, value)
  end

  defp inline_graphql_field(query, field, variables) do
    case inline_graphql_block_string_field(query, field) do
      {:ok, _value} = result -> result
      :error -> inline_graphql_quoted_string_or_variable_field(query, field, variables)
    end
  end

  defp inline_graphql_quoted_string_or_variable_field(query, field, variables) do
    case inline_graphql_string_field(query, field) do
      {:ok, _value} = result -> result
      :error -> inline_graphql_variable_field(query, field, variables)
    end
  end

  defp inline_graphql_string_field(query, field) do
    escaped_field = Regex.escape(field)

    regex =
      Regex.compile!(
        ~S/(?:^|[^a-zA-Z0-9_])/ <> escaped_field <> ~S/\s*:\s*"((?:\\.|[^"\\])*)"/,
        "s"
      )

    case Regex.run(regex, query, capture: :all_but_first) do
      [value] -> Jason.decode(~s("#{value}"))
      _ -> :error
    end
  end

  defp inline_graphql_block_string_field(query, field) do
    escaped_field = Regex.escape(field)

    regex =
      Regex.compile!(
        ~S/(?:^|[^a-zA-Z0-9_])/ <>
          escaped_field <>
          ~S/\s*:\s*"""((?:\\"""|(?:(?!""").))*)"""/,
        "s"
      )

    case Regex.run(regex, query, capture: :all_but_first) do
      [value] -> {:ok, decode_graphql_block_string(value)}
      _ -> :error
    end
  end

  defp decode_graphql_block_string(value) do
    String.replace(value, ~S(\"""), ~S("""))
  end

  defp inline_graphql_variable_field(query, field, variables) do
    escaped_field = Regex.escape(field)

    regex =
      Regex.compile!(
        ~S/(?:^|[^a-zA-Z0-9_])/ <> escaped_field <> ~S/\s*:\s*\$([_a-zA-Z][_a-zA-Z0-9]*)/,
        "s"
      )

    with [variable_name] <- Regex.run(regex, query, capture: :all_but_first),
         value when is_binary(value) <- map_get(variables, variable_name) do
      {:ok, value}
    else
      _ -> :error
    end
  end

  defp workpad_issue_id_from_input(value) when is_map(value) do
    body = map_get(value, "body")
    issue_id = map_get(value, "issueId")

    cond do
      not workpad_body?(body) ->
        :ignore

      is_binary(issue_id) and issue_id != "" ->
        {:ok, issue_id}

      true ->
        :ignore
    end
  end

  defp monotonic_ms do
    System.monotonic_time(:millisecond)
  end

  defp lock_token do
    System.unique_integer([:positive, :monotonic])
    |> Integer.to_string()
  end

  if Mix.env() == :test do
    defp write_lock_metadata_file(path, body) do
      case Application.get_env(:symphony_elixir, :workpad_bootstrap_lock_metadata_writer) do
        writer when is_function(writer, 2) -> writer.(path, body)
        _ -> File.write(path, body)
      end
    end
  else
    defp write_lock_metadata_file(path, body), do: File.write(path, body)
  end
end
