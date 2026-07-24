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

  @lock_timeout_ms 30_000
  @lock_stale_ms 60_000
  @retry_sleep_ms 50
  @workpad_marker "## Codex Workpad"

  @type linear_client :: (String.t(), map(), keyword() -> {:ok, map()} | {:error, term()})

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
    case fetch_active_workpads(linear_client, issue_id) do
      {:ok, []} ->
        create_workpad(query, variables, linear_client, issue_id)

      {:ok, comments} ->
        canonical = newest_comment(comments)

        with {:ok, resolved_ids} <- resolve_duplicate_workpads(linear_client, comments, canonical) do
          {:ok, reuse_response(canonical, resolved_ids)}
        end

      {:error, reason} ->
        {:error, reason}
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
    case fetch_active_workpads(linear_client, issue_id) do
      {:ok, comments} when comments != [] ->
        canonical = newest_comment(comments)

        case resolve_duplicate_workpads(linear_client, comments, canonical) do
          {:ok, resolved_ids} -> put_comment_create(response, canonical, false, resolved_ids)
          {:error, _reason} -> response
        end

      _ ->
        response
    end
  end

  defp fetch_active_workpads(linear_client, issue_id) do
    with {:ok, response} <- linear_client.(@active_workpad_query, %{"issueId" => issue_id}, []) do
      response
      |> comment_nodes()
      |> Enum.filter(&active_workpad_comment?/1)
      |> then(&{:ok, &1})
    end
  end

  defp workpad_create_input(query, variables) do
    cond do
      not String.contains?(query, "commentCreate") ->
        :ignore

      not workpad_body?(map_get_input(variables, "body")) ->
        :ignore

      true ->
        case map_get_input(variables, "issueId") do
          issue_id when is_binary(issue_id) and issue_id != "" -> {:ok, issue_id}
          _ -> :ignore
        end
    end
  end

  defp workpad_body?(body) when is_binary(body) do
    body
    |> String.trim_leading()
    |> String.starts_with?(@workpad_marker)
  end

  defp workpad_body?(_body), do: false

  defp active_workpad_comment?(%{} = comment) do
    workpad_body?(map_get(comment, "body")) and is_nil(map_get(comment, "resolvedAt"))
  end

  defp active_workpad_comment?(_comment), do: false

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

  defp with_issue_lock(issue_id, fun) do
    path = lock_path(issue_id)
    started_at = monotonic_ms()

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- acquire_lock(path, started_at) do
      try do
        fun.()
      after
        release_lock(path)
      end
    end
  rescue
    error in [ArgumentError, File.Error] ->
      {:error, error}
  end

  defp acquire_lock(path, started_at) do
    case File.mkdir(path) do
      :ok ->
        write_lock_metadata(path)

      {:error, :eexist} ->
        handle_existing_lock(path, started_at)

      {:error, reason} ->
        {:error, {:workpad_bootstrap_lock_create_failed, path, reason}}
    end
  end

  defp handle_existing_lock(path, started_at) do
    cond do
      lock_stale?(path) ->
        reclaim_and_reacquire_lock(path, started_at)

      monotonic_ms() - started_at >= @lock_timeout_ms ->
        {:error, {:workpad_bootstrap_lock_timeout, path}}

      true ->
        Process.sleep(@retry_sleep_ms)
        acquire_lock(path, started_at)
    end
  end

  defp reclaim_and_reacquire_lock(path, started_at) do
    case reclaim_stale_lock(path) do
      :ok -> acquire_lock(path, started_at)
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_lock_metadata(path) do
    metadata = %{
      owner_os_pid: System.pid(),
      owner_elixir_pid: self() |> :erlang.pid_to_list() |> List.to_string(),
      acquired_unix_ms: System.system_time(:millisecond)
    }

    File.write!(Path.join(path, "owner.json"), Jason.encode!(metadata))
  end

  defp reclaim_stale_lock(path) do
    reclaimed_path = "#{path}.stale-#{System.unique_integer([:positive, :monotonic])}"

    case File.rename(path, reclaimed_path) do
      :ok ->
        Logger.warning("Reclaiming stale workpad bootstrap lock path=#{path}")
        release_lock(reclaimed_path)

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, {:workpad_bootstrap_lock_reclaim_failed, path, reason}}
    end
  end

  defp release_lock(path) do
    case File.rm_rf(path) do
      {:ok, _removed} ->
        :ok

      {:error, reason, failed_path} ->
        Logger.error("Failed to remove workpad bootstrap lock path=#{path} failed_path=#{failed_path} reason=#{inspect(reason)}")
        {:error, {:workpad_bootstrap_lock_remove_failed, failed_path, reason}}
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

  defp lock_path(issue_id) do
    Config.settings!().workspace.root
    |> Path.expand()
    |> Path.join(".symphony-workpad-bootstrap-locks")
    |> Path.join(safe_key(issue_id))
  end

  defp safe_key(value) when is_binary(value) do
    String.replace(value, ~r/[^a-zA-Z0-9_-]/, "_")
  end

  defp map_get(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) || Map.get(map, String.to_atom(key))
  end

  defp map_get(_map, _key), do: nil

  defp map_get_input(map, key) when is_map(map) do
    case map_get(map, key) do
      value when is_binary(value) ->
        value

      _ ->
        map
        |> map_get("input")
        |> map_get(key)
    end
  end

  defp monotonic_ms do
    System.monotonic_time(:millisecond)
  end
end
