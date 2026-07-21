defmodule SymphonyElixir.LinearCredentialRotationTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.LinearCredentialRotation

  @viewer %{"data" => %{"viewer" => %{"id" => "viewer-1"}}}

  test "primary env check does not use bootstrap fallback" do
    graphql_fun = fn _endpoint, _key, _query, _variables ->
      flunk("primary env check should not call Linear when env is missing")
    end

    assert {:error, :missing_primary_env} =
             LinearCredentialRotation.check_primary_env(get_env: fn _ -> nil end, graphql_fun: graphql_fun)
  end

  test "primary env check validates the configured env value" do
    parent = self()

    graphql_fun = fn _endpoint, key, query, variables ->
      send(parent, {:graphql, key, query, variables})
      {:ok, @viewer}
    end

    assert :ok =
             LinearCredentialRotation.check_primary_env(
               get_env: fn "LINEAR_API_KEY" -> "primary-key-for-test" end,
               graphql_fun: graphql_fun
             )

    assert_received {:graphql, "primary-key-for-test", query, %{}}
    assert query =~ "viewer"
  end

  test "primary file check validates a file directly" do
    dir = tmp_dir()
    path = Path.join(dir, "linear.env")
    File.write!(path, "LINEAR_API_KEY=file-key-for-test\n")
    parent = self()

    graphql_fun = fn _endpoint, key, _query, _variables ->
      send(parent, {:validated, key})
      {:ok, @viewer}
    end

    assert :ok = LinearCredentialRotation.check_primary_file(path, graphql_fun: graphql_fun)
    assert_received {:validated, "file-key-for-test"}
  end

  test "rotation validates candidate, writes primary file, and validates installed primary" do
    dir = tmp_dir()
    candidate_path = Path.join(dir, "candidate.env")
    primary_path = Path.join(dir, "primary.env")
    File.write!(candidate_path, "LINEAR_API_KEY=candidate-key-for-test\n")
    parent = self()

    graphql_fun = fn _endpoint, key, _query, _variables ->
      send(parent, {:validated, key})
      {:ok, @viewer}
    end

    assert :ok =
             LinearCredentialRotation.rotate_from_candidate_file(candidate_path, primary_path, graphql_fun: graphql_fun)

    assert File.read!(primary_path) == "LINEAR_API_KEY=candidate-key-for-test\n"
    assert {:ok, stat} = File.stat(primary_path)
    assert Bitwise.band(stat.mode, 0o777) == 0o600
    assert_received {:validated, "candidate-key-for-test"}
    assert_received {:validated, "candidate-key-for-test"}
  end

  test "invalid candidate does not overwrite the primary file" do
    dir = tmp_dir()
    candidate_path = Path.join(dir, "candidate.env")
    primary_path = Path.join(dir, "primary.env")
    File.write!(candidate_path, "LINEAR_API_KEY=bad-candidate-for-test\n")
    File.write!(primary_path, "LINEAR_API_KEY=existing-primary-for-test\n")

    graphql_fun = fn _endpoint, _key, _query, _variables ->
      {:error, {:linear_api_status, 401}}
    end

    assert {:error, {:candidate_invalid, {:linear_api_status, 401}}} =
             LinearCredentialRotation.rotate_from_candidate_file(candidate_path, primary_path, graphql_fun: graphql_fun)

    assert File.read!(primary_path) == "LINEAR_API_KEY=existing-primary-for-test\n"
  end

  test "GraphQL errors are redacted to a stable failure reason" do
    graphql_fun = fn _endpoint, _key, _query, _variables ->
      {:ok, %{"errors" => [%{"message" => "nope"}]}}
    end

    assert {:error, {:primary_file_invalid, :linear_graphql_errors}} =
             "LINEAR_API_KEY=bad-key-for-test\n"
             |> write_key_file()
             |> LinearCredentialRotation.check_primary_file(graphql_fun: graphql_fun)
  end

  defp tmp_dir do
    path =
      Path.join(System.tmp_dir!(), "linear-credential-rotation-#{System.unique_integer([:positive])}")

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end

  defp write_key_file(contents) do
    path = Path.join(tmp_dir(), "key.env")
    File.write!(path, contents)
    path
  end
end
