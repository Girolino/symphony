defmodule SymphonyElixir.Linear.ClientTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Client

  @ratelimited %{"errors" => [%{"extensions" => %{"code" => "RATELIMITED"}}]}
  @auth_errors [%{"extensions" => %{"code" => "AUTHENTICATION_ERROR"}}]

  defmodule FallbackFiler do
    @spec file(String.t(), String.t(), keyword()) :: {:created, map()}
    def file(title, body, _opts) do
      send(:linear_client_test_process, {:ops_issue_filed, title, body})
      {:created, %{"identifier" => "SYM-FALLBACK", "url" => "u"}}
    end
  end

  setup do
    Process.register(self(), :linear_client_test_process)
    write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: "test-key")

    previous_fallback_filer = Application.get_env(:symphony_elixir, :linear_auth_fallback_filer)
    previous_fallback_reported = Application.get_env(:symphony_elixir, :linear_auth_fallback_reported)

    Application.delete_env(:symphony_elixir, :linear_api_key_override)
    Application.delete_env(:symphony_elixir, :linear_auth_fallback_reported)
    Application.put_env(:symphony_elixir, :linear_auth_fallback_filer, FallbackFiler)

    on_exit(fn ->
      if is_nil(previous_fallback_filer) do
        Application.delete_env(:symphony_elixir, :linear_auth_fallback_filer)
      else
        Application.put_env(:symphony_elixir, :linear_auth_fallback_filer, previous_fallback_filer)
      end

      if is_nil(previous_fallback_reported) do
        Application.delete_env(:symphony_elixir, :linear_auth_fallback_reported)
      else
        Application.put_env(:symphony_elixir, :linear_auth_fallback_reported, previous_fallback_reported)
      end
    end)

    :ok
  end

  test "retries on a RATELIMITED 200 body and eventually succeeds" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    request_fun = fn _payload, _headers ->
      n = Agent.get_and_update(counter, fn c -> {c, c + 1} end)
      if n < 2, do: {:ok, %{status: 200, body: @ratelimited}}, else: {:ok, %{status: 200, body: %{"data" => %{"ok" => true}}}}
    end

    assert {:ok, %{"data" => %{"ok" => true}}} =
             Client.graphql("query { x }", %{}, request_fun: request_fun, sleep_fun: fn _ -> :ok end)

    assert Agent.get(counter, & &1) == 3
  end

  test "retries on a 400 RATELIMITED body" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    request_fun = fn _payload, _headers ->
      n = Agent.get_and_update(counter, fn c -> {c, c + 1} end)
      if n < 1, do: {:ok, %{status: 400, body: @ratelimited}}, else: {:ok, %{status: 200, body: %{"data" => %{}}}}
    end

    assert {:ok, %{"data" => %{}}} =
             Client.graphql("query { x }", %{}, request_fun: request_fun, sleep_fun: fn _ -> :ok end)
  end

  test "gives up after the retry budget and returns the status error" do
    request_fun = fn _payload, _headers -> {:ok, %{status: 400, body: @ratelimited}} end

    assert {:error, {:linear_api_status, 400}} =
             Client.graphql("query { x }", %{}, request_fun: request_fun, sleep_fun: fn _ -> :ok end)
  end

  test "a non-rate-limit error is not retried" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    request_fun = fn _payload, _headers ->
      Agent.update(counter, &(&1 + 1))
      {:ok, %{status: 500, body: %{}}}
    end

    assert {:error, {:linear_api_status, 500}} =
             Client.graphql("query { x }", %{}, request_fun: request_fun, sleep_fun: fn _ -> :ok end)

    assert Agent.get(counter, & &1) == 1
  end

  test "retries an auth failure once with bootstrap Linear auth" do
    test_root = Path.join(System.tmp_dir!(), "linear-client-auth-#{System.unique_integer([:positive])}")
    bootstrap_path = Path.join(test_root, "env")
    previous_bootstrap_path = Application.get_env(:symphony_elixir, :linear_auth_bootstrap_path)

    on_exit(fn ->
      if is_nil(previous_bootstrap_path) do
        Application.delete_env(:symphony_elixir, :linear_auth_bootstrap_path)
      else
        Application.put_env(:symphony_elixir, :linear_auth_bootstrap_path, previous_bootstrap_path)
      end

      File.rm_rf(test_root)
    end)

    File.mkdir_p!(test_root)
    File.write!(bootstrap_path, "LINEAR_API_KEY=bootstrap-key\n")
    Application.put_env(:symphony_elixir, :linear_auth_bootstrap_path, bootstrap_path)

    request_fun = fn _payload, headers ->
      auth_header = List.keyfind(headers, "Authorization", 0)
      send(self(), {:linear_auth_header, auth_header})

      case auth_header do
        {"Authorization", "test-key"} ->
          {:ok,
           %{
             status: 401,
             body: %{"errors" => @auth_errors}
           }}

        {"Authorization", "bootstrap-key"} ->
          {:ok, %{status: 200, body: %{"data" => %{"viewer" => %{"id" => "viewer-1"}}}}}
      end
    end

    assert {:ok, %{"data" => %{"viewer" => %{"id" => "viewer-1"}}}} =
             Client.graphql("query Viewer { viewer { id } }", %{}, request_fun: request_fun)

    assert_receive {:linear_auth_header, {"Authorization", "test-key"}}
    assert_receive {:linear_auth_header, {"Authorization", "bootstrap-key"}}

    assert Application.get_env(:symphony_elixir, :linear_api_key_override) == %{
             token: "bootstrap-key",
             failed_token: "test-key"
           }

    assert_receive {:ops_issue_filed, "daemon Linear primary auth fallback in use", body}, 2_000
    assert body =~ "linear_api_status, 401"
  end

  test "credential rotation supersedes a cached fallback token" do
    test_root = Path.join(System.tmp_dir!(), "linear-client-rotation-#{System.unique_integer([:positive])}")
    bootstrap_path = Path.join(test_root, "env")
    previous_bootstrap_path = Application.get_env(:symphony_elixir, :linear_auth_bootstrap_path)

    on_exit(fn ->
      if is_nil(previous_bootstrap_path) do
        Application.delete_env(:symphony_elixir, :linear_auth_bootstrap_path)
      else
        Application.put_env(:symphony_elixir, :linear_auth_bootstrap_path, previous_bootstrap_path)
      end

      File.rm_rf(test_root)
    end)

    File.mkdir_p!(test_root)
    File.write!(bootstrap_path, "LINEAR_API_KEY=bootstrap-key\n")
    Application.put_env(:symphony_elixir, :linear_auth_bootstrap_path, bootstrap_path)

    request_fun = fn _payload, headers ->
      auth_header = List.keyfind(headers, "Authorization", 0)
      send(self(), {:linear_auth_header, auth_header})

      case auth_header do
        {"Authorization", "test-key"} ->
          {:ok, %{status: 401, body: %{"errors" => @auth_errors}}}

        {"Authorization", "bootstrap-key"} ->
          {:ok, %{status: 200, body: %{"data" => %{"viewer" => %{"id" => "viewer-1"}}}}}

        {"Authorization", "rotated-key"} ->
          {:ok, %{status: 200, body: %{"data" => %{"viewer" => %{"id" => "viewer-2"}}}}}
      end
    end

    assert {:ok, %{"data" => %{"viewer" => %{"id" => "viewer-1"}}}} =
             Client.graphql("query Viewer { viewer { id } }", %{}, request_fun: request_fun)

    assert_receive {:linear_auth_header, {"Authorization", "test-key"}}
    assert_receive {:linear_auth_header, {"Authorization", "bootstrap-key"}}

    write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: "rotated-key")

    assert {:ok, %{"data" => %{"viewer" => %{"id" => "viewer-2"}}}} =
             Client.graphql("query Viewer { viewer { id } }", %{}, request_fun: request_fun)

    assert_receive {:linear_auth_header, {"Authorization", "rotated-key"}}
    refute_receive {:linear_auth_header, {"Authorization", "bootstrap-key"}}, 250
  end

  test "fallback auth 200 authentication error is not promoted" do
    test_root = Path.join(System.tmp_dir!(), "linear-client-auth-body-#{System.unique_integer([:positive])}")
    bootstrap_path = Path.join(test_root, "env")
    previous_bootstrap_path = Application.get_env(:symphony_elixir, :linear_auth_bootstrap_path)

    on_exit(fn ->
      if is_nil(previous_bootstrap_path) do
        Application.delete_env(:symphony_elixir, :linear_auth_bootstrap_path)
      else
        Application.put_env(:symphony_elixir, :linear_auth_bootstrap_path, previous_bootstrap_path)
      end

      File.rm_rf(test_root)
    end)

    File.mkdir_p!(test_root)
    File.write!(bootstrap_path, "LINEAR_API_KEY=bootstrap-key\n")
    Application.put_env(:symphony_elixir, :linear_auth_bootstrap_path, bootstrap_path)

    request_fun = fn _payload, headers ->
      auth_header = List.keyfind(headers, "Authorization", 0)
      send(self(), {:linear_auth_header, auth_header})

      case auth_header do
        {"Authorization", "test-key"} ->
          {:ok, %{status: 401, body: %{"errors" => @auth_errors}}}

        {"Authorization", "bootstrap-key"} ->
          {:ok, %{status: 200, body: %{"errors" => @auth_errors}}}
      end
    end

    assert {:error, {:linear_graphql_errors, @auth_errors}} =
             Client.graphql("query Viewer { viewer { id } }", %{}, request_fun: request_fun)

    assert_receive {:linear_auth_header, {"Authorization", "test-key"}}
    assert_receive {:linear_auth_header, {"Authorization", "bootstrap-key"}}
    assert Application.get_env(:symphony_elixir, :linear_api_key_override) == nil
    refute_receive {:ops_issue_filed, "daemon Linear primary auth fallback in use", _body}, 250
  end
end
