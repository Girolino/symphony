defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Symphony.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.Config
  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}

  @runtime_tick_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:payload, load_payload())
      |> assign(:workflow_meta, load_workflow_meta())
      |> assign(:now, DateTime.utc_now())

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      schedule_runtime_tick()
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    {:noreply,
     socket
     |> assign(:payload, load_payload())
     |> assign(:workflow_meta, load_workflow_meta())
     |> assign(:now, DateTime.utc_now())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="operator-cockpit" aria-label="Symphony operator cockpit">
      <aside class="cockpit-sidebar" aria-label="Primary navigation">
        <a class="brand" href="/" aria-label="Homepage">
          <span class="brand-mark">S</span>
          <span class="brand-copy">
            <span class="brand-name">Symphony</span>
            <span class="brand-context"><%= tracker_label(@workflow_meta) %></span>
          </span>
        </a>

        <nav class="sidebar-nav" aria-label="Cockpit views">
          <p class="nav-section">Observe</p>
          <a class="nav-link active" href="#runtime-metrics">Runtime metrics</a>
          <a class="nav-link" href="#queue-focus">Queue focus</a>
          <a class="nav-link" href="#workflow-rail">Workflow rail</a>
          <p class="nav-section">Runtime</p>
          <a class="nav-link" href="#session-inspector">Session inspector</a>
          <a class="nav-link" href="#guardrail-ledger">Guardrail ledger</a>
          <a class="nav-link" href="#rate-limits">Rate limits</a>
        </nav>

        <div class="sidebar-footer">
          <div class="status-line">
            <span>Connection</span>
            <span class="status-badge status-badge-live">
              <span class="status-badge-dot"></span>
              Live
            </span>
            <span class="status-badge status-badge-offline">
              <span class="status-badge-dot"></span>
              Offline
            </span>
          </div>
          <div class="status-line">
            <span>Generated</span>
            <span class="mono numeric"><%= @payload.generated_at %></span>
          </div>
        </div>
      </aside>

      <div class="mobile-topbar">
        <a class="brand brand-mobile" href="/" aria-label="Homepage">
          <span class="brand-mark">S</span>
          <span class="brand-copy">
            <span class="brand-name">Symphony</span>
            <span class="brand-context"><%= tracker_label(@workflow_meta) %></span>
          </span>
        </a>

        <details class="mobile-menu">
          <summary class="mobile-menu-button" aria-label="Open navigation">
            <span class="menu-icon" aria-hidden="true"></span>
          </summary>
          <nav class="mobile-menu-panel" aria-label="Mobile cockpit views">
            <a href="#runtime-metrics">Runtime metrics</a>
            <a href="#queue-focus">Queue focus</a>
            <a href="#workflow-rail">Workflow rail</a>
            <a href="#session-inspector">Session inspector</a>
            <a href="#guardrail-ledger">Guardrail ledger</a>
            <a href="#rate-limits">Rate limits</a>
          </nav>
        </details>
      </div>

      <div class="cockpit-main">
        <header class="cockpit-toolbar">
          <div class="title-block">
            <p class="eyebrow">Symphony Observability</p>
            <h1>Operator Cockpit</h1>
            <p>
              Live queue control for <%= tracker_label(@workflow_meta) %>, <%= workflow_state_count(@workflow_meta) %> workflow states, and <%= format_int(@workflow_meta.max_concurrent_agents) %> concurrent agents.
            </p>
          </div>

          <div class="toolbar-actions" aria-label="Runtime summary">
            <span class="toolbar-chip"><%= @workflow_meta.tracker_kind %></span>
            <span class="toolbar-chip">Runtime <%= format_runtime_seconds(total_runtime_seconds(@payload, @now)) %></span>
          </div>
        </header>

        <%= if @payload[:error] do %>
          <section class="error-panel" aria-live="polite">
            <p class="panel-kicker">Snapshot</p>
            <h2>Snapshot unavailable</h2>
            <p>
              <strong><%= @payload.error.code %>:</strong> <%= @payload.error.message %>
            </p>
          </section>
        <% else %>
          <section id="runtime-metrics" class="metrics-panel" aria-label="Runtime metrics">
            <article class="metric-cell">
              <p>Running</p>
              <strong class="numeric"><%= @payload.counts.running %></strong>
              <span>Active issue sessions.</span>
            </article>
            <article class="metric-cell">
              <p>Retrying</p>
              <strong class="numeric"><%= @payload.counts.retrying %></strong>
              <span>Waiting for retry windows.</span>
            </article>
            <article class="metric-cell">
              <p>Blocked</p>
              <strong class="numeric"><%= @payload.counts.blocked %></strong>
              <span>Paused for operator input.</span>
            </article>
            <article class="metric-cell">
              <p>Total tokens</p>
              <strong class="numeric"><%= format_int(@payload.codex_totals.total_tokens) %></strong>
              <span>
                In <%= format_int(@payload.codex_totals.input_tokens) %> / Out <%= format_int(@payload.codex_totals.output_tokens) %>.
              </span>
            </article>
            <article class="metric-cell">
              <p>Runtime</p>
              <strong class="numeric"><%= format_runtime_seconds(total_runtime_seconds(@payload, @now)) %></strong>
              <span>Completed plus active Codex time.</span>
            </article>
          </section>

          <div class="cockpit-grid">
            <section id="queue-focus" class="panel queue-panel">
              <div class="panel-header">
                <div>
                  <p class="panel-kicker">Queue focus</p>
                  <h2>Active work queue</h2>
                </div>
                <span class="panel-count numeric"><%= length(runtime_rows(@payload)) %> sessions</span>
              </div>

              <%= if runtime_rows(@payload) == [] do %>
                <p class="empty-state">No active, blocked, or retrying sessions.</p>
              <% else %>
                <div class="queue-list">
                  <article :for={row <- runtime_rows(@payload)} class={row.row_class}>
                    <div class="queue-main">
                      <div class="issue-stack">
                        <span class="issue-id"><%= row.issue_identifier %></span>
                        <a class="issue-link" href={"/api/v1/#{row.issue_identifier}"}>JSON details</a>
                      </div>
                      <span class={row.state_class}><%= row.state %></span>
                    </div>

                    <div class="queue-detail">
                      <div>
                        <p class="queue-label">Codex update</p>
                        <p class="queue-headline"><%= row.headline %></p>
                        <p class="queue-meta"><%= row.meta %></p>
                      </div>
                      <div class="queue-side">
                        <p class="queue-label"><%= row.runtime_label %></p>
                        <p class="numeric"><%= row_runtime(row, @now) %></p>
                        <p class="queue-meta">Tokens <%= token_total(row.tokens) %></p>
                      </div>
                    </div>

                    <div class="queue-footer">
                      <span class="mono truncate"><%= row.workspace_path || "Workspace pending" %></span>
                      <%= if row.session_id do %>
                        <button
                          type="button"
                          class="subtle-button"
                          data-label="Copy ID"
                          data-copy={row.session_id}
                          onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                        >
                          Copy ID
                        </button>
                      <% else %>
                        <span class="muted">No session</span>
                      <% end %>
                    </div>
                  </article>
                </div>
              <% end %>
            </section>

            <aside id="session-inspector" class="panel inspector-panel">
              <p class="panel-kicker">Session inspector</p>
              <h2><%= inspector_title(@payload) %></h2>
              <p class="inspector-copy"><%= inspector_copy(@payload) %></p>

              <dl class="inspector-list">
                <div>
                  <dt>Issue</dt>
                  <dd><%= inspector_issue(@payload) %></dd>
                </div>
                <div>
                  <dt>Session</dt>
                  <dd class="mono"><%= inspector_session(@payload) %></dd>
                </div>
                <div>
                  <dt>Workspace</dt>
                  <dd class="mono"><%= inspector_workspace(@payload) %></dd>
                </div>
                <div>
                  <dt>Last event</dt>
                  <dd><%= inspector_event(@payload) %></dd>
                </div>
              </dl>
            </aside>
          </div>

          <div class="lower-grid">
            <section id="workflow-rail" class="panel rail-panel">
              <div class="panel-header">
                <div>
                  <p class="panel-kicker">Workflow rail</p>
                  <h2>Configured state bands</h2>
                </div>
                <span class="panel-count numeric"><%= workflow_state_count(@workflow_meta) %> states</span>
              </div>

              <div class="rail-list">
                <article :for={phase <- workflow_phase_items(@workflow_meta, @payload)} class={phase.class}>
                  <div class="rail-node">
                    <span class="rail-dot"></span>
                    <span class="rail-line"></span>
                  </div>
                  <div class="rail-content">
                    <div class="rail-title-row">
                      <h3><%= phase.label %></h3>
                      <span class="state-count numeric"><%= phase.count %></span>
                    </div>
                    <p><%= phase.states %></p>
                  </div>
                </article>
              </div>
            </section>

            <section id="guardrail-ledger" class="panel ledger-panel">
              <div class="panel-header">
                <div>
                  <p class="panel-kicker">Guardrail ledger</p>
                  <h2>Runtime checks</h2>
                </div>
              </div>

              <div class="ledger-list">
                <article :for={item <- guardrail_items(@payload)} class={item.class}>
                  <div>
                    <p><%= item.label %></p>
                    <span><%= item.detail %></span>
                  </div>
                  <strong class="numeric"><%= item.value %></strong>
                </article>
              </div>
            </section>
          </div>

          <section id="rate-limits" class="panel config-panel">
            <div class="panel-header">
              <div>
                <p class="panel-kicker">Configuration</p>
                <h2>Workflow and rate limits</h2>
              </div>
            </div>

            <div class="config-grid">
              <div>
                <p>Tracker</p>
                <strong><%= @workflow_meta.tracker_kind %></strong>
              </div>
              <div>
                <p>Project</p>
                <strong><%= @workflow_meta.project_slug %></strong>
              </div>
              <div>
                <p>Max turns</p>
                <strong class="numeric"><%= format_int(@workflow_meta.max_turns) %></strong>
              </div>
              <div>
                <p>Poll interval</p>
                <strong class="numeric"><%= format_milliseconds(@workflow_meta.polling_interval_ms) %></strong>
              </div>
              <div class="config-wide">
                <p>Workspace root</p>
                <strong class="mono"><%= @workflow_meta.workspace_root %></strong>
              </div>
            </div>

            <pre class="code-panel"><%= pretty_value(@payload.rate_limits) %></pre>
          </section>
        <% end %>
      </div>
    </section>
    """
  end

  defp load_payload do
    Presenter.state_payload(orchestrator(), snapshot_timeout_ms())
  end

  defp load_workflow_meta do
    settings = Config.settings!()

    %{
      tracker_kind: settings.tracker.kind || "unknown",
      project_slug: settings.tracker.project_slug || "n/a",
      active_states: settings.tracker.active_states || [],
      terminal_states: settings.tracker.terminal_states || [],
      workspace_root: settings.workspace.root,
      max_concurrent_agents: settings.agent.max_concurrent_agents,
      max_turns: settings.agent.max_turns,
      polling_interval_ms: settings.polling.interval_ms
    }
  rescue
    _ -> default_workflow_meta()
  catch
    _, _ -> default_workflow_meta()
  end

  defp default_workflow_meta do
    %{
      tracker_kind: "unknown",
      project_slug: "n/a",
      active_states: [],
      terminal_states: [],
      workspace_root: "n/a",
      max_concurrent_agents: nil,
      max_turns: nil,
      polling_interval_ms: nil
    }
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp tracker_label(%{project_slug: project_slug, tracker_kind: tracker_kind})
       when is_binary(project_slug) and project_slug not in ["", "n/a"] do
    "#{tracker_kind}:#{project_slug}"
  end

  defp tracker_label(%{tracker_kind: tracker_kind}), do: to_string(tracker_kind)

  defp workflow_state_count(%{active_states: active_states, terminal_states: terminal_states}) do
    length(active_states || []) + length(terminal_states || [])
  end

  defp focus_entry(payload) do
    cond do
      payload.running != [] -> {:running, hd(payload.running)}
      payload.blocked != [] -> {:blocked, hd(payload.blocked)}
      payload.retrying != [] -> {:retrying, hd(payload.retrying)}
      true -> {:idle, nil}
    end
  end

  defp runtime_rows(payload) do
    Enum.map(payload.running, &running_row/1) ++
      Enum.map(payload.blocked, &blocked_row/1) ++
      Enum.map(payload.retrying, &retry_row/1)
  end

  defp running_row(entry) do
    %{
      issue_identifier: entry.issue_identifier,
      state: entry.state || "Running",
      state_class: state_badge_class(entry.state || "Running"),
      headline: event_summary(entry),
      meta: event_meta(entry.last_event, entry.last_event_at),
      runtime_label: "Runtime / turns",
      started_at: entry.started_at,
      turn_count: entry.turn_count,
      due_at: nil,
      tokens: entry.tokens,
      session_id: entry.session_id,
      workspace_path: entry.workspace_path,
      row_class: "queue-row queue-row-running"
    }
  end

  defp blocked_row(entry) do
    %{
      issue_identifier: entry.issue_identifier,
      state: entry.state || "Blocked",
      state_class: state_badge_class(entry.state || "Blocked"),
      headline: event_summary(entry),
      meta: blocked_meta(entry),
      runtime_label: "Blocked",
      started_at: nil,
      turn_count: nil,
      due_at: entry.blocked_at,
      tokens: nil,
      session_id: entry.session_id,
      workspace_path: entry.workspace_path,
      row_class: "queue-row queue-row-blocked"
    }
  end

  defp blocked_meta(entry) do
    [entry.error, "Blocked at #{entry.blocked_at || "n/a"}"]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" / ")
  end

  defp retry_row(entry) do
    %{
      issue_identifier: entry.issue_identifier,
      state: "Retrying",
      state_class: state_badge_class("Retrying"),
      headline: entry.error || "Retry scheduled",
      meta: "Attempt #{entry.attempt || 0}",
      runtime_label: "Due at",
      started_at: nil,
      turn_count: nil,
      due_at: entry.due_at,
      tokens: nil,
      session_id: nil,
      workspace_path: entry.workspace_path,
      row_class: "queue-row queue-row-retry"
    }
  end

  defp row_runtime(%{started_at: started_at, turn_count: turn_count}, now) when not is_nil(started_at) do
    format_runtime_and_turns(started_at, turn_count, now)
  end

  defp row_runtime(%{due_at: due_at}, _now), do: due_at || "n/a"

  defp inspector_title(payload) do
    case focus_entry(payload) do
      {:idle, _entry} -> "No selected session"
      {_kind, entry} -> entry.issue_identifier
    end
  end

  defp inspector_copy(payload) do
    case focus_entry(payload) do
      {:running, entry} -> "Inspecting an active Codex session in #{entry.state}."
      {:blocked, _entry} -> "Inspecting a blocked worker that is waiting for operator action."
      {:retrying, _entry} -> "Inspecting a retry entry that has not re-entered execution yet."
      {:idle, _entry} -> "The inspector will populate when a worker is running, blocked, or retrying."
    end
  end

  defp inspector_issue(payload) do
    case focus_entry(payload) do
      {:idle, _entry} -> "n/a"
      {_kind, entry} -> entry.issue_identifier
    end
  end

  defp inspector_session(payload) do
    case focus_entry(payload) do
      {:running, entry} -> entry.session_id || "n/a"
      {:blocked, entry} -> entry.session_id || "n/a"
      _ -> "n/a"
    end
  end

  defp inspector_workspace(payload) do
    case focus_entry(payload) do
      {:idle, _entry} -> "n/a"
      {_kind, entry} -> Map.get(entry, :workspace_path) || "n/a"
    end
  end

  defp inspector_event(payload) do
    case focus_entry(payload) do
      {:running, entry} -> event_summary(entry)
      {:blocked, entry} -> entry.error || event_summary(entry)
      {:retrying, entry} -> entry.error || "Retry scheduled"
      {:idle, _entry} -> "n/a"
    end
  end

  defp workflow_phase_items(workflow_meta, payload) do
    states =
      (workflow_meta.active_states || []) ++
        (workflow_meta.terminal_states || [])

    build_workflow_phase_items(states, runtime_state_counts(payload))
  end

  defp build_workflow_phase_items([], _counts) do
    [%{label: "Workflow", states: "No configured states", count: 0, class: "rail-item"}]
  end

  defp build_workflow_phase_items(states, counts) do
    {items, covered} =
      phase_definitions()
      |> Enum.reduce({[], MapSet.new()}, fn definition, acc ->
        collect_phase_item(definition, acc, states, counts)
      end)

    items
    |> add_remaining_phase_item(covered, states, counts)
    |> ensure_phase_items(states)
  end

  defp collect_phase_item({label, needles}, {items, covered}, states, counts) do
    phase_states =
      states
      |> Enum.reject(&(normalize_state_name(&1) in covered))
      |> Enum.filter(&state_matches?(&1, needles))

    if phase_states == [] do
      {items, covered}
    else
      count = count_entries_for_states(counts, phase_states)
      item = phase_item(label, phase_states, count)
      {items ++ [item], cover_states(covered, phase_states)}
    end
  end

  defp add_remaining_phase_item(items, covered, states, counts) do
    remaining = Enum.reject(states, &(normalize_state_name(&1) in covered))

    if remaining == [] do
      items
    else
      items ++ [phase_item("Other states", remaining, count_entries_for_states(counts, remaining))]
    end
  end

  defp ensure_phase_items([], states) do
    [%{label: "Workflow", states: Enum.join(states, " / "), count: 0, class: "rail-item"}]
  end

  defp ensure_phase_items(items, _states), do: items

  defp phase_definitions do
    [
      {"Dispatch", ["todo", "backlog", "triage", "ready", "claimed", "queue"]},
      {"Review", ["review", "pr", "changes", "audit"]},
      {"Merge and QA", ["merge", "qa", "release", "smoke", "deploy"]},
      {"Build", ["progress", "implement", "build", "test", "verify", "active"]},
      {"Terminal", ["done", "closed", "cancel", "duplicate", "complete"]}
    ]
  end

  defp phase_item(label, states, count) do
    %{
      label: label,
      states: state_preview(states),
      count: count,
      class: if(count > 0, do: "rail-item rail-item-active", else: "rail-item")
    }
  end

  defp cover_states(covered, states) do
    Enum.reduce(states, covered, fn state, acc -> MapSet.put(acc, normalize_state_name(state)) end)
  end

  defp state_matches?(state, needles) do
    normalized = normalize_state_name(state)
    Enum.any?(needles, &String.contains?(normalized, &1))
  end

  defp runtime_state_counts(payload) do
    (payload.running ++ payload.blocked)
    |> Enum.map(&Map.get(&1, :state))
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce(%{}, fn state, counts ->
      Map.update(counts, normalize_state_name(state), 1, &(&1 + 1))
    end)
  end

  defp count_entries_for_states(counts, states) do
    Enum.reduce(states, 0, fn state, total ->
      total + Map.get(counts, normalize_state_name(state), 0)
    end)
  end

  defp state_preview(states) do
    visible = Enum.take(states, 4)
    suffix = if length(states) > length(visible), do: " / +#{length(states) - length(visible)}", else: ""
    Enum.join(visible, " / ") <> suffix
  end

  defp guardrail_items(payload) do
    [
      %{
        label: "Snapshot",
        detail: "Latest observability payload.",
        value: payload.generated_at,
        class: "ledger-item ledger-item-good"
      },
      %{
        label: "Blocked sessions",
        detail: blocked_detail(payload.counts.blocked),
        value: payload.counts.blocked,
        class: ledger_class(payload.counts.blocked, :danger)
      },
      %{
        label: "Retry pressure",
        detail: retry_detail(payload.counts.retrying),
        value: payload.counts.retrying,
        class: ledger_class(payload.counts.retrying, :warning)
      },
      %{
        label: "Rate limits",
        detail: "Latest upstream limit payload.",
        value: rate_limit_summary(payload.rate_limits),
        class: "ledger-item"
      }
    ]
  end

  defp ledger_class(0, _tone), do: "ledger-item ledger-item-good"
  defp ledger_class(_count, :danger), do: "ledger-item ledger-item-danger"
  defp ledger_class(_count, :warning), do: "ledger-item ledger-item-warning"

  defp blocked_detail(0), do: "No workers are waiting for input."
  defp blocked_detail(_count), do: "Operator action is required."

  defp retry_detail(0), do: "No entries are backing off."
  defp retry_detail(_count), do: "Backoff queue is active."

  defp rate_limit_summary(nil), do: "n/a"

  defp rate_limit_summary(%{} = limits) do
    Enum.find_value(limits, fn {_bucket, value} ->
      remaining = map_value(value, :remaining) || map_value(value, "remaining")
      if is_integer(remaining), do: "#{remaining} remaining"
    end) || "available"
  end

  defp rate_limit_summary(_limits), do: "available"

  defp map_value(%{} = map, key), do: Map.get(map, key)
  defp map_value(_value, _key), do: nil

  defp token_total(%{total_tokens: total_tokens}), do: format_int(total_tokens)
  defp token_total(_tokens), do: "n/a"

  defp event_summary(%{last_message: message}) when is_binary(message) and message != "", do: message
  defp event_summary(%{last_event: event}), do: event_label(event)
  defp event_summary(_entry), do: "No Codex update"

  defp event_meta(event, nil), do: event_label(event)
  defp event_meta(event, timestamp), do: "#{event_label(event)} at #{timestamp}"

  defp event_label(nil), do: "n/a"
  defp event_label(event), do: event |> to_string() |> String.replace("_", " ")

  defp normalize_state_name(state) do
    state
    |> to_string()
    |> String.downcase()
    |> String.trim()
  end

  defp completed_runtime_seconds(payload) do
    payload.codex_totals.seconds_running || 0
  end

  defp total_runtime_seconds(%{error: _error}, _now), do: 0

  defp total_runtime_seconds(payload, now) do
    completed_runtime_seconds(payload) +
      Enum.reduce(payload.running, 0, fn entry, total ->
        total + runtime_seconds_from_started_at(entry.started_at, now)
      end)
  end

  defp format_runtime_and_turns(started_at, turn_count, now) when is_integer(turn_count) and turn_count > 0 do
    "#{format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))} / #{turn_count}"
  end

  defp format_runtime_and_turns(started_at, _turn_count, now),
    do: format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))

  defp format_runtime_seconds(seconds) when is_number(seconds) do
    whole_seconds = max(trunc(seconds), 0)
    mins = div(whole_seconds, 60)
    secs = rem(whole_seconds, 60)
    "#{mins}m #{secs}s"
  end

  defp format_milliseconds(milliseconds) when is_integer(milliseconds) do
    seconds = milliseconds / 1_000

    if seconds >= 60 do
      "#{Float.round(seconds / 60, 1)}m"
    else
      "#{Float.round(seconds, 1)}s"
    end
  end

  defp format_milliseconds(_milliseconds), do: "n/a"

  defp runtime_seconds_from_started_at(%DateTime{} = started_at, %DateTime{} = now) do
    DateTime.diff(now, started_at, :second)
  end

  defp runtime_seconds_from_started_at(started_at, %DateTime{} = now) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, parsed, _offset} -> runtime_seconds_from_started_at(parsed, now)
      _ -> 0
    end
  end

  defp runtime_seconds_from_started_at(_started_at, _now), do: 0

  defp format_int(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  defp format_int(_value), do: "n/a"

  defp state_badge_class(state) do
    base = "state-badge"
    normalized = normalize_state_name(state)

    cond do
      String.contains?(normalized, ["progress", "running", "active", "implement"]) ->
        "#{base} state-badge-active"

      String.contains?(normalized, ["blocked", "error", "failed"]) ->
        "#{base} state-badge-danger"

      String.contains?(normalized, ["todo", "queued", "pending", "retry", "ready"]) ->
        "#{base} state-badge-warning"

      String.contains?(normalized, ["review", "merge", "qa", "release", "done", "closed"]) ->
        "#{base} state-badge-clean"

      true ->
        base
    end
  end

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end

  defp pretty_value(nil), do: "n/a"
  defp pretty_value(value), do: inspect(value, pretty: true, limit: :infinity)
end
