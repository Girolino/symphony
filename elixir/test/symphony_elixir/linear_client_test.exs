defmodule SymphonyElixir.Linear.ClientTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Client

  @ratelimited %{"errors" => [%{"extensions" => %{"code" => "RATELIMITED"}}]}

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: "test-key")

    Application.delete_env(:symphony_elixir, :linear_api_key_override)

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
             body: %{"errors" => [%{"extensions" => %{"code" => "AUTHENTICATION_ERROR"}}]}
           }}

        {"Authorization", "bootstrap-key"} ->
          {:ok, %{status: 200, body: %{"data" => %{"viewer" => %{"id" => "viewer-1"}}}}}
      end
    end

    assert {:ok, %{"data" => %{"viewer" => %{"id" => "viewer-1"}}}} =
             Client.graphql("query Viewer { viewer { id } }", %{}, request_fun: request_fun)

    assert_receive {:linear_auth_header, {"Authorization", "test-key"}}
    assert_receive {:linear_auth_header, {"Authorization", "bootstrap-key"}}
    assert Application.get_env(:symphony_elixir, :linear_api_key_override) == "bootstrap-key"
  end
end
