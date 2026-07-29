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

  test "gives up after the retry budget with a distinct tracker_rate_limited error" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    request_fun = fn _payload, _headers ->
      Agent.update(counter, &(&1 + 1))
      {:ok, %{status: 400, body: @ratelimited}}
    end

    assert {:error, {:tracker_rate_limited, %{status: 400, retry_after_ms: nil}}} =
             Client.graphql("query { x }", %{}, request_fun: request_fun, sleep_fun: fn _ -> :ok end)

    # bounded: initial attempt + 3 retries, never an unbounded hammer loop
    assert Agent.get(counter, & &1) == 4
  end

  test "an exhausted RATELIMITED 200 body fails instead of masquerading as success" do
    request_fun = fn _payload, _headers -> {:ok, %{status: 200, body: @ratelimited}} end

    assert {:error, {:tracker_rate_limited, %{status: 200}}} =
             Client.graphql("query { x }", %{}, request_fun: request_fun, sleep_fun: fn _ -> :ok end)
  end

  test "handles HTTP 429 with retries and surfaces Retry-After from headers" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    {:ok, delays} = Agent.start_link(fn -> [] end)

    request_fun = fn _payload, _headers ->
      Agent.update(counter, &(&1 + 1))
      {:ok, %{status: 429, headers: %{"retry-after" => ["3"]}, body: %{}}}
    end

    assert {:error, {:tracker_rate_limited, %{status: 429, retry_after_ms: 3_000}}} =
             Client.graphql("query { x }", %{},
               request_fun: request_fun,
               sleep_fun: fn ms -> Agent.update(delays, &[ms | &1]) end
             )

    assert Agent.get(counter, & &1) == 4

    recorded = Agent.get(delays, &Enum.reverse/1)
    assert length(recorded) == 3
    # Retry-After (3s) is honored, not the smaller default first backoff (2s)
    assert Enum.all?(recorded, fn ms -> ms >= 3_000 and ms <= 4_000 end)
    # and the enforced cumulative budget is respected, not just the per-delay clamp
    assert Enum.sum(recorded) <= 15_000
  end

  test "a Retry-After header on a 200 RATELIMITED body is honored, not discarded" do
    {:ok, delays} = Agent.start_link(fn -> [] end)

    # Linear's most common rate-limit shape: HTTP 200, RATELIMITED error body, and
    # the wait hint only in the HTTP header. Rebuilding a synthetic response from
    # the body alone would silently drop it.
    request_fun = fn _payload, _headers ->
      {:ok, %{status: 200, headers: %{"retry-after" => ["6"]}, body: @ratelimited}}
    end

    assert {:error, {:tracker_rate_limited, %{status: 200, retry_after_ms: 6_000}}} =
             Client.graphql("query { x }", %{},
               request_fun: request_fun,
               sleep_fun: fn ms -> Agent.update(delays, &[ms | &1]) end
             )

    recorded = Agent.get(delays, &Enum.reverse/1)
    assert recorded != []
    assert Enum.all?(recorded, fn ms -> ms >= 6_000 and ms <= 7_000 end)
  end

  test "a server hint longer than the max backoff stops retrying instead of retrying early" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    # Retrying at 8s into a 120s throttle window is a guaranteed-doomed request:
    # give up immediately and let the caller reconcile later.
    request_fun = fn _payload, _headers ->
      Agent.update(counter, &(&1 + 1))
      {:ok, %{status: 429, headers: %{"retry-after" => ["120"]}, body: %{}}}
    end

    assert {:error, {:tracker_rate_limited, %{status: 429, retry_after_ms: 120_000}}} =
             Client.graphql("query { x }", %{},
               request_fun: request_fun,
               sleep_fun: fn _ -> flunk("must not sleep for a hint beyond the backoff cap") end
             )

    assert Agent.get(counter, & &1) == 1
  end

  test "the cumulative retry budget is enforced, not decorative" do
    {:ok, delays} = Agent.start_link(fn -> [] end)

    request_fun = fn _payload, _headers ->
      {:ok, %{status: 429, headers: %{"retry-after" => ["8"]}, body: %{}}}
    end

    assert {:error, {:tracker_rate_limited, %{status: 429}}} =
             Client.graphql("query { x }", %{},
               request_fun: request_fun,
               sleep_fun: fn ms -> Agent.update(delays, &[ms | &1]) end
             )

    recorded = Agent.get(delays, &Enum.reverse/1)
    # 3 retries x ~8s would be ~24s; the budget stops it at 1 retry
    assert length(recorded) == 1
    assert Enum.sum(recorded) <= 15_000
  end

  test "a transport error on a mutation is never replayed" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    # The write may already have been applied server-side and only the response
    # lost; replaying it duplicates the comment/state transition.
    request_fun = fn _payload, _headers ->
      Agent.update(counter, &(&1 + 1))
      {:error, %Req.TransportError{reason: :closed}}
    end

    assert {:error, {:linear_api_request, %Req.TransportError{reason: :closed}}} =
             Client.graphql("mutation { commentCreate(input: {}) { success } }", %{},
               request_fun: request_fun,
               sleep_fun: fn _ -> :ok end
             )

    assert Agent.get(counter, & &1) == 1
  end

  test "test runs fail closed instead of posting default live Linear mutations" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_endpoint: "http://127.0.0.1:1/graphql")

    assert {:error, :test_live_linear_mutation_disabled} =
             Client.graphql("mutation { issueUpdate(id: \"x\") { success } }", %{})
  end

  test "test mutation guard rejects invalid injected request transports" do
    assert {:error, :test_live_linear_mutation_disabled} =
             Client.graphql("mutation { issueUpdate(id: \"x\") { success } }", %{}, request_fun: :invalid)
  end

  test "live e2e mutation opt-in requires the environment flag and explicit option" do
    previous_live_e2e_flag = System.get_env("SYMPHONY_RUN_LIVE_E2E")

    on_exit(fn ->
      restore_env("SYMPHONY_RUN_LIVE_E2E", previous_live_e2e_flag)
    end)

    mutation = "mutation { issueUpdate(id: \"x\") { success } }"
    write_workflow_file!(Workflow.workflow_file_path(), tracker_endpoint: "http://127.0.0.1:1/graphql")
    System.delete_env("SYMPHONY_RUN_LIVE_E2E")

    assert {:error, :test_live_linear_mutation_disabled} =
             Client.graphql(mutation, %{}, allow_test_live_linear_mutation: true)

    System.put_env("SYMPHONY_RUN_LIVE_E2E", "1")

    assert {:error, :test_live_linear_mutation_disabled} = Client.graphql(mutation, %{})

    assert {:error, {:linear_api_request, %{reason: :econnrefused}}} =
             Client.graphql(mutation, %{}, allow_test_live_linear_mutation: true)
  end

  test "a rate-limited mutation is still retried, because the request was rejected not applied" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    request_fun = fn _payload, _headers ->
      n = Agent.get_and_update(counter, fn c -> {c, c + 1} end)

      if n < 1,
        do: {:ok, %{status: 400, body: @ratelimited}},
        else: {:ok, %{status: 200, body: %{"data" => %{"ok" => true}}}}
    end

    assert {:ok, %{"data" => %{"ok" => true}}} =
             Client.graphql("mutation { issueUpdate(id: \"x\") { success } }", %{},
               request_fun: request_fun,
               sleep_fun: fn _ -> :ok end
             )

    assert Agent.get(counter, & &1) == 2
  end

  test "429 succeeds once the throttle clears" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    request_fun = fn _payload, _headers ->
      n = Agent.get_and_update(counter, fn c -> {c, c + 1} end)

      if n < 1,
        do: {:ok, %{status: 429, body: %{}}},
        else: {:ok, %{status: 200, body: %{"data" => %{"ok" => true}}}}
    end

    assert {:ok, %{"data" => %{"ok" => true}}} =
             Client.graphql("query { x }", %{}, request_fun: request_fun, sleep_fun: fn _ -> :ok end)
  end

  test "retries a transient transport close and then succeeds" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    request_fun = fn _payload, _headers ->
      n = Agent.get_and_update(counter, fn c -> {c, c + 1} end)

      if n < 2,
        do: {:error, %Req.TransportError{reason: :closed}},
        else: {:ok, %{status: 200, body: %{"data" => %{"ok" => true}}}}
    end

    assert {:ok, %{"data" => %{"ok" => true}}} =
             Client.graphql("query { x }", %{}, request_fun: request_fun, sleep_fun: fn _ -> :ok end)

    assert Agent.get(counter, & &1) == 3
  end

  test "a non-retryable transport error fails through unchanged" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    request_fun = fn _payload, _headers ->
      Agent.update(counter, &(&1 + 1))
      {:error, %Req.TransportError{reason: :nxdomain}}
    end

    assert {:error, {:linear_api_request, %Req.TransportError{reason: :nxdomain}}} =
             Client.graphql("query { x }", %{}, request_fun: request_fun, sleep_fun: fn _ -> :ok end)

    assert Agent.get(counter, & &1) == 1
  end

  test "a non-rate-limit GraphQL validation error is not retried" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    body = %{"errors" => [%{"extensions" => %{"code" => "GRAPHQL_VALIDATION_FAILED"}}]}

    request_fun = fn _payload, _headers ->
      Agent.update(counter, &(&1 + 1))
      {:ok, %{status: 400, body: body}}
    end

    assert {:error, {:linear_api_status, 400}} =
             Client.graphql("query { x }", %{}, request_fun: request_fun, sleep_fun: fn _ -> :ok end)

    assert Agent.get(counter, & &1) == 1
  end

  test "retry backoff is exponential with equal jitter and bounded" do
    first = for _ <- 1..200, do: Client.retry_delay_ms(0)
    second = for _ <- 1..200, do: Client.retry_delay_ms(1)

    assert Enum.all?(first, fn ms -> ms >= 1_000 and ms <= 2_000 end)
    assert Enum.all?(second, fn ms -> ms >= 2_000 and ms <= 4_000 end)

    # Equal jitter, not a narrow additive band: the whole point is decorrelating a
    # fleet of daemons sharing one API key when the throttle window resets, so the
    # spread has to be a real fraction of the delay.
    assert Enum.max(first) - Enum.min(first) > 500

    # server hint wins, with a little jitter so concurrent daemons still spread
    assert Client.retry_delay_ms(0, 5_000) >= 5_000
    assert Client.retry_delay_ms(0, 5_000) <= 6_000

    # the ladder is clamped
    assert Client.retry_delay_ms(9, nil) <= 8_000
    assert Client.retry_delay_ms(0, 600_000) <= 9_000
  end

  test "graphql payloads are classified for replay safety" do
    assert Client.idempotent_payload?(%{"query" => "query { issues { id } }"})
    assert Client.idempotent_payload?(%{"query" => "{ issues { id } }"})
    refute Client.idempotent_payload?(%{"query" => "mutation { commentCreate { success } }"})
    refute Client.idempotent_payload?(%{"query" => "  MUTATION Foo { x }"})
    refute Client.idempotent_payload?(%{})
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
