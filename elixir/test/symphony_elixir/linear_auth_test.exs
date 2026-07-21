defmodule SymphonyElixir.LinearAuthTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Auth

  setup do
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")
    System.delete_env("LINEAR_API_KEY")

    on_exit(fn -> restore_env("LINEAR_API_KEY", previous_linear_api_key) end)

    :ok
  end

  test "parses quoted Linear bootstrap keys" do
    assert {:ok, "abc"} = Auth.parse_api_key_file(~s(LINEAR_API_KEY="abc"\n))
    assert {:ok, "abc"} = Auth.parse_api_key_file("LINEAR_API_KEY='abc'\n")
    assert {:error, :missing_key} = Auth.parse_api_key_file("LINEAR_API_KEY=\n")
    assert {:error, :missing_key} = Auth.parse_api_key_file("OTHER=value\n")
  end

  test "resolves configured, env, and bootstrap Linear keys in order" do
    bootstrap_path = Path.join(System.tmp_dir!(), "linear-auth-#{System.unique_integer([:positive])}.env")
    File.write!(bootstrap_path, "LINEAR_API_KEY=bootstrap-key\n")

    env_fun = fn
      "LINEAR_API_KEY" -> "env-key"
      _name -> nil
    end

    assert {:ok, "configured-key"} =
             Auth.resolve_api_key("configured-key", get_env: env_fun, bootstrap_path: bootstrap_path)

    assert {:ok, "env-key"} =
             Auth.resolve_api_key(nil, get_env: env_fun, bootstrap_path: bootstrap_path)

    assert {:ok, "bootstrap-key"} =
             Auth.resolve_api_key(nil, get_env: fn _name -> nil end, bootstrap_path: bootstrap_path)

    assert {:error, :missing_linear_api_token} =
             Auth.resolve_api_key(nil,
               get_env: fn _name -> nil end,
               bootstrap_path: bootstrap_path <> ".missing"
             )
  end
end
