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

  @spec release(t()) :: :ok
  def release(%{path: path, token: token}) when is_binary(path) and is_binary(token) do
    case read_metadata(path) do
      {:ok, %{"token" => ^token}} ->
        File.rm_rf(path)
        :ok

      _ ->
        :ok
    end
  end

  def release(_lease), do: :ok

  defp do_acquire(path, issue_key, issue_or_identifier, worker_host, attempt) do
    case File.mkdir(path) do
      :ok ->
        token = lease_token()
        metadata = metadata(token, issue_key, issue_or_identifier, worker_host)
        File.write!(metadata_path(path), Jason.encode!(metadata))
        {:ok, %{path: path, token: token, issue_key: issue_key}}

      {:error, :eexist} ->
        maybe_reclaim_stale_lease(path, issue_key, issue_or_identifier, worker_host, attempt)

      {:error, reason} ->
        {:error, {:agent_run_lease_create_failed, path, reason}}
    end
  end

  defp maybe_reclaim_stale_lease(path, issue_key, issue_or_identifier, worker_host, attempt) do
    cond do
      stale?(path) and attempt < 2 ->
        Logger.warning("Reclaiming stale agent run lease issue_key=#{issue_key} path=#{path}")
        File.rm_rf(path)
        do_acquire(path, issue_key, issue_or_identifier, worker_host, attempt + 1)

      stale?(path) ->
        {:error, {:agent_run_lease_stale_reclaim_failed, path}}

      true ->
        :busy
    end
  end

  defp stale?(path) do
    case read_metadata(path) do
      {:ok, metadata} ->
        stale_metadata?(metadata)

      {:error, :missing_metadata} ->
        lease_age_ms(path) > @metadata_grace_ms

      {:error, _reason} ->
        lease_age_ms(path) > @metadata_grace_ms
    end
  end

  defp stale_metadata?(%{"owner_os_pid" => owner_os_pid, "acquired_unix_ms" => acquired_unix_ms})
       when is_binary(owner_os_pid) and is_integer(acquired_unix_ms) do
    !os_pid_alive?(owner_os_pid)
  end

  defp stale_metadata?(_metadata), do: false

  defp os_pid_alive?(owner_os_pid) do
    cond do
      owner_os_pid == System.pid() ->
        true

      !integer_string?(owner_os_pid) ->
        true

      true ->
        case System.cmd("kill", ["-0", owner_os_pid], stderr_to_stdout: true) do
          {_output, 0} -> true
          _ -> false
        end
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

  defp metadata(token, issue_key, issue_or_identifier, worker_host) do
    %{
      token: token,
      issue_key: issue_key,
      issue_id: issue_id(issue_or_identifier),
      issue_identifier: issue_identifier(issue_or_identifier),
      worker_host: worker_host,
      owner_os_pid: System.pid(),
      acquired_unix_ms: current_unix_ms()
    }
  end

  defp metadata_path(path), do: Path.join(path, "owner.json")

  defp lease_path(issue_key) do
    Config.settings!().workspace.root
    |> Path.expand()
    |> Path.join(".symphony-run-locks")
    |> Path.join(safe_key(issue_key))
  end

  defp issue_key(issue_or_identifier) do
    issue_id(issue_or_identifier) || issue_identifier(issue_or_identifier) || "unknown-issue"
  end

  defp issue_id(%{id: id}) when is_binary(id) and id != "", do: id
  defp issue_id(_issue_or_identifier), do: nil

  defp issue_identifier(%{identifier: identifier}) when is_binary(identifier) and identifier != "", do: identifier
  defp issue_identifier(identifier) when is_binary(identifier) and identifier != "", do: identifier
  defp issue_identifier(_issue_or_identifier), do: nil

  defp safe_key(value) when is_binary(value) do
    String.replace(value, ~r/[^a-zA-Z0-9._-]/, "_")
  end

  defp lease_token do
    System.unique_integer([:positive, :monotonic])
    |> Integer.to_string()
  end

  defp current_unix_ms do
    System.system_time(:millisecond)
  end
end
