defmodule SymphonyElixirWeb.ObservabilityApiController do
  @moduledoc """
  JSON API for Symphony observability data.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixirWeb.{Endpoint, Presenter}

  @spec state(Conn.t(), map()) :: Conn.t()
  def state(conn, _params) do
    json(conn, Presenter.state_payload(orchestrator(), snapshot_timeout_ms()))
  end

  @spec issue(Conn.t(), map()) :: Conn.t()
  def issue(conn, %{"issue_identifier" => issue_identifier}) do
    case Presenter.issue_payload(issue_identifier, orchestrator(), snapshot_timeout_ms()) do
      {:ok, payload} ->
        json(conn, payload)

      {:error, :issue_not_found} ->
        error_response(conn, 404, "issue_not_found", "Issue not found")
    end
  end

  @spec refresh(Conn.t(), map()) :: Conn.t()
  def refresh(conn, _params) do
    case Presenter.refresh_payload(orchestrator(), snapshot_timeout_ms()) do
      {:ok, payload} ->
        conn
        |> put_status(202)
        |> json(payload)

      {:error, :unavailable} ->
        error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")

      {:error, %{reason: :timeout, message_queue_len: message_queue_len}} ->
        error_response(
          conn,
          503,
          "orchestrator_refresh_timeout",
          "Orchestrator refresh timed out",
          %{message_queue_len: message_queue_len}
        )

      {:error, %{message_queue_len: message_queue_len}} ->
        error_response(
          conn,
          503,
          "orchestrator_unavailable",
          "Orchestrator is unavailable",
          %{message_queue_len: message_queue_len}
        )
    end
  end

  @spec pause_dispatch(Conn.t(), map()) :: Conn.t()
  def pause_dispatch(conn, _params) do
    case SymphonyElixir.DispatchPause.pause() do
      :ok ->
        notify_observability_change()
        json(conn, Map.put(SymphonyElixir.DispatchPause.status(), :dispatch_paused, true))

      {:error, reason} ->
        error_response(conn, 500, "pause_write_failed", "Could not persist pause flag: #{inspect(reason)}")
    end
  end

  @spec resume_dispatch(Conn.t(), map()) :: Conn.t()
  def resume_dispatch(conn, _params) do
    case SymphonyElixir.DispatchPause.resume() do
      :ok ->
        notify_observability_change()
        json(conn, %{dispatch_paused: false, paused: false, paused_at: nil})

      {:error, reason} ->
        error_response(conn, 500, "resume_failed", "Could not remove pause flag: #{inspect(reason)}")
    end
  end

  defp notify_observability_change do
    SymphonyElixir.Orchestrator.request_refresh(orchestrator())
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  @spec method_not_allowed(Conn.t(), map()) :: Conn.t()
  def method_not_allowed(conn, _params) do
    error_response(conn, 405, "method_not_allowed", "Method not allowed")
  end

  @spec not_found(Conn.t(), map()) :: Conn.t()
  def not_found(conn, _params) do
    error_response(conn, 404, "not_found", "Route not found")
  end

  defp error_response(conn, status, code, message) do
    error_response(conn, status, code, message, %{})
  end

  defp error_response(conn, status, code, message, details) do
    conn
    |> put_status(status)
    |> json(%{error: Map.merge(%{code: code, message: message}, details)})
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end
end
