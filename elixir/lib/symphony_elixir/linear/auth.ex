defmodule SymphonyElixir.Linear.Auth do
  @moduledoc """
  Resolves Linear API credentials for daemon-side tracker calls.
  """

  @spec default_bootstrap_path() :: String.t()
  def default_bootstrap_path do
    Application.get_env(:symphony_elixir, :linear_auth_bootstrap_path, compute_default_bootstrap_path())
  end

  @spec resolve_api_key(String.t() | nil, keyword()) :: {:ok, String.t()} | {:error, :missing_linear_api_token}
  def resolve_api_key(configured_token, opts \\ []) do
    case resolve_api_key_without_override(configured_token, opts) do
      {:ok, token} ->
        {:ok, runtime_api_key_override(token) || token}

      {:error, :missing_linear_api_token} ->
        {:error, :missing_linear_api_token}
    end
  end

  @spec parse_api_key_file(String.t()) :: {:ok, String.t()} | {:error, :missing_key}
  def parse_api_key_file(contents) when is_binary(contents) do
    case parse_bootstrap_api_key(contents) do
      token when is_binary(token) -> {:ok, token}
      nil -> {:error, :missing_key}
    end
  end

  @spec put_runtime_api_key_override(String.t(), String.t() | nil) :: :ok
  def put_runtime_api_key_override(token, failed_token \\ nil) when is_binary(token) do
    Application.put_env(:symphony_elixir, :linear_api_key_override, %{
      token: normalize_secret_value(token),
      failed_token: normalize_secret_value(failed_token)
    })
  end

  @spec clear_runtime_api_key_override() :: :ok
  def clear_runtime_api_key_override do
    Application.delete_env(:symphony_elixir, :linear_api_key_override)
  end

  @spec runtime_api_key_override() :: String.t() | nil
  def runtime_api_key_override do
    :symphony_elixir
    |> Application.get_env(:linear_api_key_override)
    |> runtime_override_token()
  end

  @spec runtime_api_key_override(String.t() | nil) :: String.t() | nil
  def runtime_api_key_override(current_token) do
    current = normalize_secret_value(current_token)

    case Application.get_env(:symphony_elixir, :linear_api_key_override) do
      %{token: token, failed_token: ^current} ->
        normalize_secret_value(token)

      _override ->
        nil
    end
  end

  @spec fallback_api_key(String.t() | nil, keyword()) :: {:ok, String.t()} | :none
  def fallback_api_key(current_token, opts \\ []) do
    current = normalize_secret_value(current_token)

    opts
    |> bootstrap_api_key()
    |> case do
      token when is_binary(token) and token != current -> {:ok, token}
      _ -> :none
    end
  end

  defp fallback_to_env(token, _opts) when is_binary(token), do: {:ok, token}
  defp fallback_to_env(nil, opts), do: opts |> env_api_key() |> fallback_to_bootstrap(opts)

  defp fallback_to_bootstrap(token, _opts) when is_binary(token), do: {:ok, token}

  defp fallback_to_bootstrap(nil, opts) do
    case bootstrap_api_key(opts) do
      token when is_binary(token) -> {:ok, token}
      nil -> {:error, :missing_linear_api_token}
    end
  end

  defp env_api_key(opts) do
    opts
    |> get_env_fun()
    |> then(& &1.("LINEAR_API_KEY"))
    |> normalize_secret_value()
  end

  defp bootstrap_api_key(opts) do
    opts
    |> bootstrap_path()
    |> File.read()
    |> case do
      {:ok, contents} -> parse_bootstrap_api_key(contents)
      {:error, _reason} -> nil
    end
  end

  defp parse_bootstrap_api_key(contents) when is_binary(contents) do
    case Regex.run(~r/^LINEAR_API_KEY=(.*)$/m, contents) do
      [_, value] ->
        value
        |> String.trim()
        |> String.trim_leading("\"")
        |> String.trim_trailing("\"")
        |> String.trim_leading("'")
        |> String.trim_trailing("'")
        |> normalize_secret_value()

      _ ->
        nil
    end
  end

  defp normalize_secret_value(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      token -> token
    end
  end

  defp normalize_secret_value(_value), do: nil

  defp get_env_fun(opts), do: Keyword.get(opts, :get_env, &System.get_env/1)

  defp bootstrap_path(opts) do
    Keyword.get(
      opts,
      :bootstrap_path,
      default_bootstrap_path()
    )
  end

  defp resolve_api_key_without_override(configured_token, opts) do
    configured_token
    |> configured_api_key(opts)
    |> fallback_to_env(opts)
  end

  defp configured_api_key(configured_token, opts) do
    configured_token
    |> normalize_secret_value()
    |> expand_env_reference(opts)
  end

  defp expand_env_reference(nil, _opts), do: nil

  defp expand_env_reference("$" <> _ = token, opts) do
    case env_reference_name(token) do
      {:ok, name} ->
        opts
        |> get_env_fun()
        |> then(& &1.(name))
        |> normalize_secret_value()

      :error ->
        token
    end
  end

  defp expand_env_reference(token, _opts), do: token

  defp env_reference_name("$" <> raw_name) do
    case raw_name do
      "{" <> rest ->
        case String.split(rest, "}", parts: 2) do
          [name, ""] -> valid_env_reference_name(name)
          _ -> :error
        end

      name ->
        valid_env_reference_name(name)
    end
  end

  defp valid_env_reference_name(name) when is_binary(name) do
    if Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*$/, name) do
      {:ok, name}
    else
      :error
    end
  end

  defp runtime_override_token(%{token: token}), do: normalize_secret_value(token)
  defp runtime_override_token(token), do: normalize_secret_value(token)

  defp compute_default_bootstrap_path do
    Path.join([System.user_home!(), ".config", "linear-codex", "env"])
  end
end
