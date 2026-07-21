defmodule Mix.Tasks.Linear.RotateCredentialTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Linear.RotateCredential

  defmodule PassingRunner do
    @spec default_primary_path() :: String.t()
    def default_primary_path, do: "/tmp/default-primary.env"

    @spec check_primary_env(keyword()) :: :ok
    def check_primary_env(opts) do
      send(self(), {:check_primary_env, opts})
      :ok
    end

    @spec check_primary_file(String.t(), keyword()) :: :ok
    def check_primary_file(path, opts) do
      send(self(), {:check_primary_file, path, opts})
      :ok
    end

    @spec rotate_from_candidate_file(String.t(), String.t(), keyword()) :: :ok
    def rotate_from_candidate_file(candidate_path, primary_path, opts) do
      send(self(), {:rotate, candidate_path, primary_path, opts})
      :ok
    end
  end

  defmodule FailingRunner do
    @spec check_primary_env(keyword()) :: {:error, term()}
    def check_primary_env(_opts), do: {:error, {:primary_env_invalid, {:linear_api_status, 401}}}
  end

  setup do
    on_exit(fn -> Application.delete_env(:symphony_elixir, :linear_credential_rotation) end)
    :ok
  end

  test "checks primary env without fallback" do
    Application.put_env(:symphony_elixir, :linear_credential_rotation, PassingRunner)

    output =
      capture_io(fn ->
        RotateCredential.run(["--check-primary"])
      end)

    assert output =~ "primary env valid"
    assert output =~ "value redacted"
    assert_received {:check_primary_env, []}
  end

  test "checks primary file directly" do
    Application.put_env(:symphony_elixir, :linear_credential_rotation, PassingRunner)

    output =
      capture_io(fn ->
        RotateCredential.run(["--check-primary-file", "/tmp/primary.env"])
      end)

    assert output =~ "primary file valid"
    assert_received {:check_primary_file, "/tmp/primary.env", []}
  end

  test "rotates candidate into explicit primary file" do
    Application.put_env(:symphony_elixir, :linear_credential_rotation, PassingRunner)

    output =
      capture_io(fn ->
        RotateCredential.run(["--candidate-file", "/tmp/candidate.env", "--primary-file", "/tmp/primary.env"])
      end)

    assert output =~ "rotated primary file"
    assert_received {:rotate, "/tmp/candidate.env", "/tmp/primary.env", []}
  end

  test "exits non-zero with redacted failure output" do
    Application.put_env(:symphony_elixir, :linear_credential_rotation, FailingRunner)

    output =
      capture_io(:stderr, fn ->
        assert catch_exit(RotateCredential.run(["--check-primary"])) == {:shutdown, 1}
      end)

    assert output =~ "primary env returned Linear HTTP 401"
    refute output =~ "LINEAR_API_KEY="
  end

  test "requires exactly one operation mode" do
    assert_raise Mix.Error, ~r/choose exactly one/, fn ->
      RotateCredential.run([])
    end
  end

  test "rejects multiple operation modes" do
    assert_raise Mix.Error, ~r/choose exactly one/, fn ->
      RotateCredential.run(["--check-primary", "--candidate-file", "/tmp/candidate.env"])
    end
  end

  test "raises on invalid options" do
    assert_raise Mix.Error, ~r/invalid options/, fn ->
      RotateCredential.run(["--bogus"])
    end
  end
end
