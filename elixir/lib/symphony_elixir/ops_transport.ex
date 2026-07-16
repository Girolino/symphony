defmodule SymphonyElixir.OpsTransport do
  @moduledoc """
  Real-IO adapter for the autonomy machinery (prod smoke, ops issue filing).

  Keeps network and OS-process side effects out of the journey logic so
  `SymphonyElixir.ProdSmoke` and `SymphonyElixir.OpsIssue` stay fully
  unit-testable with fakes. Mirrors the `SymphonyElixir.Linear.Client`
  precedent: transport-only module, excluded from the coverage gate.
  """

  @doc """
  Posts a GraphQL request with the Linear auth header. Retries twice on 429
  with a fixed backoff because the workspace API budget is shared with the
  live lanes.
  """
  @spec graphql(String.t(), String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def graphql(endpoint, api_key, query, variables) do
    graphql_with_retry(endpoint, api_key, query, variables, 2)
  end

  @doc """
  Plain GET returning `{:ok, status, body}` with the body as a binary.
  """
  @spec http_get(String.t()) :: {:ok, non_neg_integer(), String.t()} | {:error, term()}
  def http_get(url) do
    case Req.get(url, retry: false, receive_timeout: 10_000, decode_body: false) do
      {:ok, %Req.Response{status: status, body: body}} when is_binary(body) -> {:ok, status, body}
      {:ok, %Req.Response{status: status, body: body}} -> {:ok, status, Jason.encode!(body)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Spawns the Symphony escript as a supervised OS process. The API key reaches
  the daemon only through its environment.
  """
  @spec spawn_daemon(String.t(), String.t(), non_neg_integer(), map()) ::
          {:ok, map()} | {:error, term()}
  def spawn_daemon(escript_path, workflow_path, port, env) do
    logs_root = Map.get(env, "LOGS_ROOT", Path.join(System.tmp_dir!(), "symphony-prod-smoke-logs"))
    File.mkdir_p!(logs_root)

    port_ref =
      Port.open({:spawn_executable, escript_path}, [
        :binary,
        :exit_status,
        :hide,
        args: [
          "--i-understand-that-this-will-be-running-without-the-usual-guardrails",
          workflow_path,
          "--logs-root",
          logs_root,
          "--port",
          Integer.to_string(port)
        ],
        env: [
          {~c"LINEAR_API_KEY", String.to_charlist(Map.fetch!(env, "LINEAR_API_KEY"))},
          # Interactive agent sessions export NODE_OPTIONS preloads pointing at
          # session-scoped tmp files; a codex (Node) subprocess inheriting them
          # dies at boot. The daemon must see a clean Node environment.
          {~c"NODE_OPTIONS", false}
        ]
      ])

    case Port.info(port_ref, :os_pid) do
      {:os_pid, os_pid} -> {:ok, %{port: port_ref, os_pid: os_pid}}
      nil -> {:error, :daemon_exited_immediately}
    end
  rescue
    error -> {:error, error}
  end

  @doc """
  Stops a daemon spawned by `spawn_daemon/4`: TERM first, KILL after 10s.
  """
  @spec stop_daemon(map()) :: :ok
  def stop_daemon(%{port: port_ref, os_pid: os_pid}) do
    System.cmd("kill", ["-TERM", Integer.to_string(os_pid)], stderr_to_stdout: true)

    receive do
      {^port_ref, {:exit_status, _status}} -> :ok
    after
      10_000 ->
        System.cmd("kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)
        :ok
    end
  catch
    _kind, _reason -> :ok
  end

  defp graphql_with_retry(endpoint, api_key, query, variables, retries_left) do
    response =
      Req.post(endpoint,
        json: %{query: query, variables: variables},
        headers: [{"authorization", api_key}, {"content-type", "application/json"}],
        retry: false,
        receive_timeout: 30_000
      )

    case response do
      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: 429}} when retries_left > 0 ->
        Process.sleep(15_000)
        graphql_with_retry(endpoint, api_key, query, variables, retries_left - 1)

      {:ok, %Req.Response{status: status}} ->
        {:error, {:linear_api_status, status}}

      {:error, reason} ->
        {:error, {:linear_api_request, reason}}
    end
  end
end
