defmodule Mix.Tasks.Linear.RotateCredential do
  use Mix.Task

  alias SymphonyElixir.LinearCredentialRotation

  @moduledoc """
  Validates or rotates the Linear primary credential without printing values.

      mix linear.rotate_credential --check-primary
      mix linear.rotate_credential --check-primary-file ~/.config/linear-codex/env
      mix linear.rotate_credential --candidate-file <candidate-env-file> \
                                   [--primary-file ~/.config/linear-codex/env]

  `--check-primary` validates only the live `LINEAR_API_KEY` environment
  variable. It does not use the bootstrap file fallback.

  Rotation validates the candidate env file against Linear, writes the primary
  env file atomically, then validates the installed primary file.
  """
  @shortdoc "Validates or rotates the Linear primary credential"

  @switches [
    check_primary: :boolean,
    check_primary_file: :string,
    candidate_file: :string,
    primary_file: :string
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      Mix.raise("linear.rotate_credential: invalid options #{inspect(invalid)}")
    end

    {:ok, _apps} = Application.ensure_all_started(:req)
    runner = Application.get_env(:symphony_elixir, :linear_credential_rotation, LinearCredentialRotation)

    case operation(opts, runner) do
      :ok ->
        Mix.shell().info(success_message(opts))

      {:error, reason} ->
        Mix.shell().error("linear.rotate_credential failed: #{failure_message(reason)}")
        exit({:shutdown, 1})
    end
  end

  defp operation(opts, runner) do
    if operation_count(opts) != 1 do
      Mix.raise("linear.rotate_credential: choose exactly one of --check-primary, --check-primary-file, or --candidate-file")
    end

    cond do
      opts[:check_primary] ->
        runner.check_primary_env([])

      is_binary(opts[:check_primary_file]) ->
        runner.check_primary_file(opts[:check_primary_file], [])

      is_binary(opts[:candidate_file]) ->
        primary_file = opts[:primary_file] || runner.default_primary_path()
        runner.rotate_from_candidate_file(opts[:candidate_file], primary_file, [])
    end
  end

  defp operation_count(opts) do
    [
      opts[:check_primary],
      is_binary(opts[:check_primary_file]),
      is_binary(opts[:candidate_file])
    ]
    |> Enum.count(& &1)
  end

  defp success_message(opts) do
    cond do
      opts[:check_primary] ->
        "linear.rotate_credential primary env valid (value redacted)"

      is_binary(opts[:check_primary_file]) ->
        "linear.rotate_credential primary file valid (value redacted)"

      true ->
        "linear.rotate_credential rotated primary file and validated it (value redacted)"
    end
  end

  defp failure_message(:missing_primary_env), do: "primary env missing"
  defp failure_message(:missing_key), do: "credential file missing LINEAR_API_KEY"
  defp failure_message(:missing_key_file), do: "credential file missing"

  defp failure_message({:read_key_file_failed, reason}) do
    "credential file read failed: #{inspect(reason)}"
  end

  defp failure_message({:write_primary_file_failed, reason}) do
    "primary file write failed: #{inspect(reason)}"
  end

  defp failure_message({tag, {:linear_api_status, status}})
       when tag in [:primary_env_invalid, :primary_file_invalid, :candidate_invalid] do
    "#{friendly_tag(tag)} returned Linear HTTP #{status}"
  end

  defp failure_message({tag, reason})
       when tag in [:primary_env_invalid, :primary_file_invalid, :candidate_invalid] do
    "#{friendly_tag(tag)} validation failed: #{inspect(reason)}"
  end

  defp failure_message(reason), do: inspect(reason)

  defp friendly_tag(:primary_env_invalid), do: "primary env"
  defp friendly_tag(:primary_file_invalid), do: "primary file"
  defp friendly_tag(:candidate_invalid), do: "candidate"
end
