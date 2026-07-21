defmodule SymphonyElixir.LinearCredentialRotation do
  @moduledoc """
  Repo-local automation for Linear primary credential checks and rotation.

  The primary environment check validates only `LINEAR_API_KEY` from the
  current process environment. It intentionally does not use the documented
  bootstrap file fallback, so operators and lanes can distinguish a healthy
  primary credential from fallback recovery.

  Rotation accepts a candidate env file, validates the candidate with Linear's
  viewer query, writes the primary env file atomically, then validates the
  installed primary file. If installed-file validation fails, the previous
  primary file is restored. Credential values are never returned or logged.
  """

  alias SymphonyElixir.{OpsTransport, ProdSmoke}

  @linear_endpoint "https://api.linear.app/graphql"
  @viewer_query """
  query SymphonyLinearCredentialViewer {
    viewer {
      id
    }
  }
  """

  @type result :: :ok | {:error, term()}

  @doc """
  Returns the default persistent Linear env file path.
  """
  @spec default_primary_path() :: String.t()
  def default_primary_path, do: ProdSmoke.default_bootstrap_path()

  @doc """
  Validates the current primary process credential without bootstrap fallback.
  """
  @spec check_primary_env(keyword()) :: result()
  def check_primary_env(opts \\ []) do
    get_env = Keyword.get(opts, :get_env, &System.get_env/1)

    case get_env.("LINEAR_API_KEY") do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, :missing_primary_env}
          key -> validate_key(key, opts, :primary_env)
        end

      _ ->
        {:error, :missing_primary_env}
    end
  end

  @doc """
  Validates a primary env file directly without consulting any fallback.
  """
  @spec check_primary_file(String.t(), keyword()) :: result()
  def check_primary_file(path, opts \\ []) when is_binary(path) do
    with {:ok, key} <- read_key_file(path) do
      validate_key(key, opts, :primary_file)
    end
  end

  @doc """
  Validates a candidate env file, installs it as the primary env file, and
  revalidates the installed primary file.
  """
  @spec rotate_from_candidate_file(String.t(), String.t(), keyword()) :: result()
  def rotate_from_candidate_file(candidate_path, primary_path \\ default_primary_path(), opts \\ [])
      when is_binary(candidate_path) and is_binary(primary_path) do
    with {:ok, candidate_key} <- read_key_file(candidate_path),
         :ok <- validate_key(candidate_key, opts, :candidate),
         {:ok, previous_primary} <- snapshot_primary_file(primary_path),
         :ok <- write_primary_file(primary_path, candidate_key) do
      case check_primary_file(primary_path, opts) do
        :ok -> :ok
        {:error, reason} -> restore_after_failed_install(primary_path, previous_primary, reason)
      end
    end
  end

  defp read_key_file(path) do
    with true <- File.exists?(path),
         {:ok, contents} <- File.read(path) do
      ProdSmoke.parse_api_key_file(contents)
    else
      false -> {:error, :missing_key_file}
      {:error, reason} -> {:error, {:read_key_file_failed, reason}}
    end
  end

  defp validate_key(key, opts, source) do
    graphql_fun = Keyword.get(opts, :graphql_fun, &OpsTransport.graphql/4)
    endpoint = Keyword.get(opts, :endpoint, @linear_endpoint)

    case graphql_fun.(endpoint, key, @viewer_query, %{}) do
      {:ok, %{"data" => %{"viewer" => %{"id" => id}}}} when is_binary(id) and id != "" ->
        :ok

      {:ok, %{"errors" => errors}} when is_list(errors) ->
        {:error, {invalid_tag(source), :linear_graphql_errors}}

      {:ok, _payload} ->
        {:error, {invalid_tag(source), :unexpected_linear_payload}}

      {:error, reason} ->
        {:error, {invalid_tag(source), normalize_transport_error(reason)}}
    end
  end

  defp invalid_tag(:primary_env), do: :primary_env_invalid
  defp invalid_tag(:primary_file), do: :primary_file_invalid
  defp invalid_tag(:candidate), do: :candidate_invalid

  defp normalize_transport_error({:linear_api_status, status}) when is_integer(status) do
    {:linear_api_status, status}
  end

  defp normalize_transport_error({:linear_api_request, _reason}), do: :linear_api_request
  defp normalize_transport_error(_reason), do: :linear_api_request

  defp snapshot_primary_file(path) do
    case File.read(path) do
      {:ok, contents} ->
        {:ok, {:existing, contents, file_mode(path)}}

      {:error, :enoent} ->
        {:ok, :missing}

      {:error, reason} ->
        {:error, {:read_primary_file_failed, reason}}
    end
  end

  defp file_mode(path) do
    case File.stat(path) do
      {:ok, stat} -> Bitwise.band(stat.mode, 0o777)
      {:error, _reason} -> 0o600
    end
  end

  defp restore_after_failed_install(path, previous_primary, validation_reason) do
    case restore_primary_file(path, previous_primary) do
      :ok -> {:error, validation_reason}
      {:error, restore_reason} -> {:error, {:installed_primary_unverified, validation_reason, restore_reason}}
    end
  end

  defp restore_primary_file(path, :missing) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:restore_primary_file_failed, reason}}
    end
  end

  defp restore_primary_file(path, {:existing, contents, mode}) do
    dir = Path.dirname(path)
    tmp_path = Path.join(dir, ".#{Path.basename(path)}.restore.#{System.unique_integer([:positive])}.tmp")

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(tmp_path, contents, [:write, :exclusive]),
         :ok <- File.chmod(tmp_path, mode),
         :ok <- File.rename(tmp_path, path),
         :ok <- File.chmod(path, mode) do
      :ok
    else
      {:error, reason} ->
        File.rm(tmp_path)
        {:error, {:restore_primary_file_failed, reason}}
    end
  end

  defp write_primary_file(path, key) do
    dir = Path.dirname(path)
    tmp_path = Path.join(dir, ".#{Path.basename(path)}.#{System.unique_integer([:positive])}.tmp")

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(tmp_path, "LINEAR_API_KEY=#{key}\n", [:write, :exclusive]),
         :ok <- File.chmod(tmp_path, 0o600),
         :ok <- File.rename(tmp_path, path),
         :ok <- File.chmod(path, 0o600) do
      :ok
    else
      {:error, reason} ->
        File.rm(tmp_path)
        {:error, {:write_primary_file_failed, reason}}
    end
  end
end
