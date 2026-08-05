defmodule SymphonyElixir.DispatchPause do
  @moduledoc """
  Operator-controlled dispatch pause.

  Pausing drains the lane: the orchestrator keeps reconciling running, retrying,
  and blocked issues, but claims no new work until resumed. Running agents are
  never interrupted. The flag lives on disk so it survives daemon restarts and
  launchd reconciles.
  """

  @spec paused?() :: boolean()
  def paused?, do: File.exists?(pause_file())

  @spec status() :: %{paused: boolean(), paused_at: String.t() | nil}
  def status do
    case File.read(pause_file()) do
      {:ok, contents} ->
        paused_at =
          case Jason.decode(contents) do
            {:ok, %{"paused_at" => paused_at}} when is_binary(paused_at) -> paused_at
            _ -> nil
          end

        %{paused: true, paused_at: paused_at}

      {:error, _} ->
        %{paused: false, paused_at: nil}
    end
  end

  @spec pause() :: :ok | {:error, File.posix()}
  def pause do
    path = pause_file()

    with :ok <- File.mkdir_p(Path.dirname(path)) do
      payload =
        Jason.encode!(%{
          paused_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
          by: "dashboard"
        })

      File.write(path, payload)
    end
  end

  @spec resume() :: :ok
  def resume do
    case File.rm(pause_file()) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, _} = error -> error
    end
  end

  @spec pause_file() :: Path.t()
  def pause_file do
    case System.get_env("SYMPHONY_DISPATCH_PAUSE_FILE") do
      path when is_binary(path) and path != "" ->
        path

      _ ->
        Path.join([System.user_home!(), ".cache", "symphony", "dispatch-paused.json"])
    end
  end
end
