defmodule SymphonyElixir.Linear.Auth do
  @moduledoc """
  Resolves Linear API credentials for daemon-side tracker calls.
  """

  @default_bootstrap_path Path.join([System.user_home!(), ".config", "linear-codex", "env"])

  @spec default_bootstrap_path() :: String.t()
  def default_bootstrap_path do
    Application.get_env(:symphony_elixir, :linear_auth_bootstrap_path, @default_bootstrap_path)
  end

  @spec resolve_api_key(String.t() | nil, keyword()) :: {:ok, String.t()} | {:error, :missing_linear_api_token}
  def resolve_api_key(configured_token, opts \\ []) do
    case runtime_api_key_override() do
      token when is_binary(token) ->
        {:ok, token}

      nil ->
        configured_token
        |> normalize_secret_value()
        |> fallback_to_env(opts)
    end
  end

  @spec parse_api_key_file(String.t()) :: {:ok, String.t()} | {:error, :missing_key}
  def parse_api_key_file(contents) when is_binary(contents) do
    case parse_bootstrap_api_key(contents) do
      token when is_binary(token) -> {:ok, token}
      nil -> {:error, :missing_key}
    end
  end

  @spec put_runtime_api_key_override(String.t()) :: :ok
  def put_runtime_api_key_override(token) when is_binary(token) do
    Application.put_env(:symphony_elixir, :linear_api_key_override, token)
  end

  @spec runtime_api_key_override() :: String.t() | nil
  def runtime_api_key_override do
    :symphony_elixir
    |> Application.get_env(:linear_api_key_override)
    |> normalize_secret_value()
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
end
