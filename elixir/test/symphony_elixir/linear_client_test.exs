defmodule SymphonyElixir.Linear.ClientTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Client

  @ratelimited %{"errors" => [%{"extensions" => %{"code" => "RATELIMITED"}}]}

  setup do
    write_workflow_file!(Path.join(System.tmp_dir!(), "client-test-#{System.unique_integer([:positive])}.md"),
      tracker_api_token: "test-key"
    )

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
end
