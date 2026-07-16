defmodule Mix.Tasks.Prod.SmokeTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Prod.Smoke

  defmodule PassingRunner do
    @spec run(keyword()) :: {:ok, map()}
    def run(opts) do
      send(self(), {:smoke_opts, opts})
      {:ok, %{result: :pass, duration_ms: 123, failure: nil}}
    end
  end

  defmodule FailingRunner do
    @spec run(keyword()) :: {:error, map()}
    def run(_opts) do
      {:error, %{result: :fail, duration_ms: 5, failure: "await-completion: timed out"}}
    end
  end

  setup do
    on_exit(fn -> Application.delete_env(:symphony_elixir, :prod_smoke_runner) end)
    :ok
  end

  test "prints PASS and forwards parsed options" do
    Application.put_env(:symphony_elixir, :prod_smoke_runner, PassingRunner)

    output =
      capture_io(fn ->
        Smoke.run(["--port", "4711", "--escript-path", "/tmp/symphony"])
      end)

    assert output =~ "prod.smoke PASS in 123ms"
    assert_received {:smoke_opts, opts}
    assert opts[:port] == 4711
    assert opts[:escript_path] == "/tmp/symphony"
  end

  test "exits non-zero on FAIL" do
    Application.put_env(:symphony_elixir, :prod_smoke_runner, FailingRunner)

    output =
      capture_io(:stderr, fn ->
        assert catch_exit(Smoke.run([])) == {:shutdown, 1}
      end)

    assert output =~ "prod.smoke FAIL: await-completion: timed out"
  end

  test "raises on invalid options" do
    assert_raise Mix.Error, ~r/invalid options/, fn ->
      Smoke.run(["--bogus"])
    end
  end
end
