defmodule SymphonyElixir.AgentRunLease do
  @moduledoc """
  Coordinates local agent starts so one issue has at most one active runner.

  The orchestrator's in-memory claim set protects a single daemon process. This
  lease adds a filesystem-backed guard for stale snapshots or concurrent daemon
  processes sharing the same workspace root.
  """

  require Logger
  alias SymphonyElixir.Config

  @metadata_grace_ms 5_000

  @type worker_host :: String.t() | nil
  @type t :: %{
          path: Path.t(),
          token: String.t(),
          issue_key: String.t()
        }

  @spec acquire(map() | String.t() | nil, worker_host()) :: {:ok, t()} | :busy | {:error, term()}
  def acquire(issue_or_identifier, worker_host \\ nil) do
    issue_key = issue_key(issue_or_identifier)
    path = lease_path(issue_key)

    with :ok <- File.mkdir_p(Path.dirname(path)) do
      do_acquire(path, issue_key, issue_or_identifier, worker_host, 0)
    end
  rescue
    error in [ArgumentError, File.Error] ->
      {:error, error}
  end

  @spec release(t()) :: :ok | {:error, term()}
  def release(%{path: path, token: token}) when is_binary(path) and is_binary(token) do
    case read_metadata(path) do
      {:ok, %{"token" => ^token}} ->
        remove_path(path, :release)

      _ ->
        :ok
    end
  end

  def release(_lease), do: :ok

  defp do_acquire(path, issue_key, issue_or_identifier, worker_host, attempt) do
    case File.mkdir(path) do
      :ok ->
        write_lease_metadata(path, issue_key, issue_or_identifier, worker_host)

      {:error, :eexist} ->
        maybe_reclaim_stale_lease(path, issue_key, issue_or_identifier, worker_host, attempt)

      {:error, reason} ->
        {:error, {:agent_run_lease_create_failed, path, reason}}
    end
  end

  defp maybe_reclaim_stale_lease(path, issue_key, issue_or_identifier, worker_host, attempt) do
    case stale?(path) do
      true when attempt < 2 ->
        reclaim_stale_lease(path, issue_key, issue_or_identifier, worker_host, attempt)

      true ->
        {:error, {:agent_run_lease_stale_reclaim_failed, path}}

      false ->
        :busy
    end
  end

  defp reclaim_stale_lease(path, issue_key, issue_or_identifier, worker_host, attempt) do
    reclaim_path = reclaim_lock_path(path)

    notify_reclaim_observer(:stale_snapshot, %{
      attempt: attempt,
      issue_key: issue_key,
      path: path,
      reclaim_path: reclaim_path
    })

    with :ok <- create_reclaim_lock(reclaim_path) do
      with_reclaim_lock(reclaim_path, issue_key, fn ->
        reclaim_then_acquire(path, issue_key, issue_or_identifier, worker_host)
      end)
    end
  end

  defp create_reclaim_lock(reclaim_path) do
    case File.mkdir(reclaim_path) do
      :ok -> :ok
      {:error, :eexist} -> maybe_reclaim_stale_reclaim_lock(reclaim_path)
      {:error, reason} -> {:error, {:agent_run_lease_reclaim_lock_failed, reclaim_path, reason}}
    end
  end

  defp maybe_reclaim_stale_reclaim_lock(reclaim_path) do
    with :ok <- move_stale_reclaim_lock(reclaim_path) do
      create_reclaim_lock(reclaim_path)
    end
  end

  defp move_stale_reclaim_lock(reclaim_path) do
    cond do
      File.exists?(reclaim_path) and not stale?(reclaim_path) ->
        :busy

      File.exists?(reclaim_path) ->
        reclaimed_path = reclaimed_lease_path(reclaim_path)

        case File.rename(reclaim_path, reclaimed_path) do
          :ok ->
            Logger.warning("Reclaiming stale agent run lease reclaim lock path=#{reclaim_path}")
            remove_path(reclaimed_path, :stale_reclaim_lock)

          {:error, :enoent} ->
            :ok

          {:error, reason} ->
            {:error, {:agent_run_lease_reclaim_lock_rename_failed, reclaim_path, reason}}
        end

      true ->
        :ok
    end
  end

  defp reclaim_then_acquire(path, issue_key, issue_or_identifier, worker_host) do
    with :ok <- move_current_stale_lease(path, issue_key) do
      do_acquire_after_reclaim(path, issue_key, issue_or_identifier, worker_host)
    end
  end

  defp do_acquire_after_reclaim(path, issue_key, issue_or_identifier, worker_host) do
    case File.mkdir(path) do
      :ok ->
        write_lease_metadata(path, issue_key, issue_or_identifier, worker_host)

      {:error, :eexist} ->
        :busy

      {:error, reason} ->
        {:error, {:agent_run_lease_create_failed, path, reason}}
    end
  end

  defp with_reclaim_lock(reclaim_path, issue_key, fun) do
    write_reclaim_lock_metadata!(reclaim_path, issue_key)
    result = fun.()

    with :ok <- remove_path(reclaim_path, :reclaim_lock) do
      result
    end
  after
    if File.exists?(reclaim_path), do: remove_path(reclaim_path, :reclaim_lock)
  end

  defp move_current_stale_lease(path, issue_key) do
    cond do
      File.exists?(path) and not stale?(path) ->
        :busy

      File.exists?(path) ->
        move_stale_lease(path, issue_key)

      true ->
        :ok
    end
  end

  defp move_stale_lease(path, issue_key) do
    reclaimed_path = reclaimed_lease_path(path)

    case File.rename(path, reclaimed_path) do
      :ok ->
        Logger.warning("Reclaiming stale agent run lease issue_key=#{issue_key} path=#{path}")
        remove_path(reclaimed_path, :stale_reclaim)

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, {:agent_run_lease_reclaim_rename_failed, path, reason}}
    end
  end

  defp stale?(path) do
    case read_metadata(path) do
      {:ok, metadata} ->
        case metadata_stale_status(metadata) do
          {:known, stale?} -> stale?
          :unknown -> lease_age_ms(path) > @metadata_grace_ms
        end

      {:error, :missing_metadata} ->
        lease_age_ms(path) > @metadata_grace_ms

      {:error, _reason} ->
        lease_age_ms(path) > @metadata_grace_ms
    end
  end

  defp metadata_stale_status(%{
         "owner_os_pid" => owner_os_pid,
         "owner_elixir_pid" => owner_elixir_pid,
         "acquired_unix_ms" => acquired_unix_ms
       })
       when is_binary(owner_os_pid) and is_binary(owner_elixir_pid) and is_integer(acquired_unix_ms) do
    {:known, owner_process_stale?(owner_os_pid, owner_elixir_pid)}
  end

  defp metadata_stale_status(%{"owner_os_pid" => owner_os_pid, "acquired_unix_ms" => acquired_unix_ms})
       when is_binary(owner_os_pid) and is_integer(acquired_unix_ms) do
    if owner_os_pid == System.pid() do
      :unknown
    else
      {:known, !os_pid_alive?(owner_os_pid)}
    end
  end

  defp metadata_stale_status(_metadata), do: :unknown

  defp owner_process_stale?(owner_os_pid, owner_elixir_pid) do
    if owner_os_pid == System.pid() do
      not local_elixir_pid_alive?(owner_elixir_pid)
    else
      not os_pid_alive?(owner_os_pid)
    end
  end

  defp local_elixir_pid_alive?(owner_elixir_pid) do
    owner_elixir_pid
    |> String.to_charlist()
    |> :erlang.list_to_pid()
    |> Process.alive?()
  rescue
    _error -> true
  end

  defp os_pid_alive?(owner_os_pid) do
    if integer_string?(owner_os_pid) do
      case System.cmd("kill", ["-0", owner_os_pid], stderr_to_stdout: true) do
        {_output, 0} -> true
        _ -> false
      end
    else
      true
    end
  rescue
    _error -> true
  end

  defp integer_string?(value) when is_binary(value) do
    case Integer.parse(value) do
      {_integer, ""} -> true
      _ -> false
    end
  end

  defp lease_age_ms(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime}} when is_integer(mtime) ->
        current_unix_ms() - mtime * 1_000

      _ ->
        0
    end
  end

  defp read_metadata(path) do
    path
    |> metadata_path()
    |> File.read()
    |> case do
      {:ok, body} -> Jason.decode(body)
      {:error, :enoent} -> {:error, :missing_metadata}
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_lease_metadata(path, issue_key, issue_or_identifier, worker_host) do
    token = lease_token()
    metadata = metadata(token, issue_key, issue_or_identifier, worker_host)
    File.write!(metadata_path(path), Jason.encode!(metadata))
    {:ok, %{path: path, token: token, issue_key: issue_key}}
  end

  defp write_reclaim_lock_metadata!(path, issue_key) do
    metadata =
      metadata(lease_token(), "#{issue_key}:reclaim", nil, nil)
      |> Jason.encode!()

    File.write!(metadata_path(path), metadata)
  end

  defp metadata(token, issue_key, issue_or_identifier, worker_host) do
    %{
      token: token,
      issue_key: issue_key,
      issue_id: issue_id(issue_or_identifier),
      issue_identifier: issue_identifier(issue_or_identifier),
      worker_host: worker_host,
      owner_os_pid: System.pid(),
      owner_elixir_pid: owner_elixir_pid(),
      acquired_unix_ms: current_unix_ms()
    }
  end

  defp remove_path(path, reason) do
    case File.rm_rf(path) do
      {:ok, _removed} ->
        :ok

      {:error, error_reason, offending_path} ->
        Logger.error(
          "Failed to remove agent run lease path=#{path} reason=#{inspect(error_reason)} " <>
            "offending_path=#{offending_path}"
        )

        {:error, {:agent_run_lease_remove_failed, reason, offending_path, error_reason}}
    end
  end

  defp metadata_path(path), do: Path.join(path, "owner.json")

  defp reclaimed_lease_path(path), do: "#{path}.stale-#{lease_token()}"

  defp reclaim_lock_path(path), do: "#{path}.reclaiming"

  defp lease_path(issue_key) do
    Config.settings!().workspace.root
    |> Path.expand()
    |> Path.join(".symphony-run-locks")
    |> Path.join(safe_key(issue_key))
  end

  defp issue_key(issue_or_identifier) do
    issue_id(issue_or_identifier) || issue_identifier(issue_or_identifier) ||
      unknown_issue_key(issue_or_identifier)
  end

  defp issue_id(%{id: id}) when is_binary(id) and id != "", do: id
  defp issue_id(_issue_or_identifier), do: nil

  defp issue_identifier(%{identifier: identifier}) when is_binary(identifier) and identifier != "", do: identifier
  defp issue_identifier(identifier) when is_binary(identifier) and identifier != "", do: identifier
  defp issue_identifier(_issue_or_identifier), do: nil

  defp safe_key(value) when is_binary(value) do
    String.replace(value, ~r/[^a-zA-Z0-9_-]/, "_")
  end

  defp unknown_issue_key(issue_or_identifier) do
    fingerprint =
      issue_or_identifier
      |> :erlang.phash2()
      |> Integer.to_string(36)

    fallback_key = "unknown-issue-#{fingerprint}"

    Logger.warning(
      "Agent run lease requested for an issue with no id or identifier; " <>
        "using fallback issue_key=#{fallback_key}"
    )

    fallback_key
  end

  defp lease_token do
    System.unique_integer([:positive, :monotonic])
    |> Integer.to_string()
  end

  defp owner_elixir_pid do
    self()
    |> :erlang.pid_to_list()
    |> List.to_string()
  end

  if Mix.env() == :test do
    defp notify_reclaim_observer(event, metadata) do
      case Application.get_env(:symphony_elixir, :agent_run_lease_reclaim_observer) do
        observer when is_function(observer, 2) -> observer.(event, metadata)
        _ -> :ok
      end
    end
  else
    defp notify_reclaim_observer(_event, _metadata), do: :ok
  end

  defp current_unix_ms do
    System.system_time(:millisecond)
  end
end
