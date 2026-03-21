defmodule SymphonyElixirWeb.SessionsLive do
  @moduledoc """
  Session lane page for Symphony observability.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixirWeb.{Endpoint, Layouts, ObservabilityPubSub, Presenter}

  @runtime_tick_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:payload, load_payload())
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
     |> assign(:now, DateTime.utc_now())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.dashboard_frame active_section="sessions" counts={sidebar_counts(@payload)}>
      <section class="dashboard-shell">
        <header class="hero-card page-hero-card">
          <div class="page-hero-grid">
            <div class="page-hero-main">
              <p class="eyebrow">Sessions</p>
              <h1 class="hero-title page-hero-title">Execution Lanes</h1>
              <p class="hero-copy page-hero-copy">
                Dedicated monitoring for active threads, retry backlog, and the latest codex updates without local issue creation controls getting in the way.
              </p>

              <div class="hero-toolbar">
                <nav class="hero-section-nav" aria-label="Sessions quick actions">
                  <a class="hero-action-button" href="/">
                    <strong>Overview</strong>
                    <span>Return to runtime posture</span>
                  </a>

                  <a class="hero-action-button" href="/issues">
                    <strong>Issue board</strong>
                    <span>Move work through the local queue</span>
                  </a>
                </nav>

                <div class="hero-utility-row">
                  <a
                    class="hero-utility-button"
                    href="/api/v1/state"
                    target="_blank"
                    rel="noreferrer"
                  >
                    <strong>State API</strong>
                    <span>Inspect the latest snapshot JSON</span>
                  </a>
                </div>

                <p class="hero-toolbar-copy">
                  Use this page as the live lane view, then jump back to the board when an issue needs routing or recovery.
                </p>
              </div>

              <div :if={!@payload[:error]} class="page-hero-chip-grid">
                <article class="page-hero-chip">
                  <span>Lane health</span>
                  <strong><%= if @payload.counts.running > 0, do: "Live", else: "Idle" %></strong>
                  <p class="page-hero-chip-copy">Execution lanes ready for active issue sessions.</p>
                </article>

                <article class="page-hero-chip">
                  <span>Retry posture</span>
                  <strong><%= if @payload.counts.retrying > 0, do: "Watching", else: "Stable" %></strong>
                  <p class="page-hero-chip-copy">Backoff queue stays isolated from running work.</p>
                </article>

                <article class="page-hero-chip">
                  <span>Workspace links</span>
                  <strong>Ready</strong>
                  <p class="page-hero-chip-copy">Every live or retry row links straight into issue workspace.</p>
                </article>
              </div>
            </div>

            <div class="page-hero-side">
              <article class="page-hero-side-card">
                <p class="metric-label">Live sessions</p>
                <p class="page-hero-side-value"><%= @payload[:counts] && @payload.counts.running || 0 %></p>
              </article>

              <article class="page-hero-side-card">
                <p class="metric-label">Retry queue</p>
                <p class="page-hero-side-value"><%= @payload[:counts] && @payload.counts.retrying || 0 %></p>
              </article>
            </div>
          </div>
        </header>

        <%= if @payload[:error] do %>
          <section class="error-card">
            <h2 class="error-title">Snapshot unavailable</h2>
            <p class="error-copy">
              <strong><%= @payload.error.code %>:</strong> <%= @payload.error.message %>
            </p>
          </section>
        <% else %>
          <section class="section-card">
            <div class="section-header">
              <div>
                <h2 class="section-title">Running sessions</h2>
                <p class="section-copy">Active issues, last known agent activity, and token usage.</p>
              </div>
            </div>

            <%= if @payload.running == [] do %>
              <div class="empty-state-panel">
                <strong>Lane idle</strong>
                <p class="empty-state">
                  No active sessions right now. Launch work from the issue board and live execution will appear here automatically.
                </p>
              </div>
            <% else %>
              <div class="table-wrap">
                <table class="data-table data-table-running">
                  <colgroup>
                    <col style="width: 12rem;" />
                    <col style="width: 8rem;" />
                    <col style="width: 7.5rem;" />
                    <col style="width: 8.5rem;" />
                    <col />
                    <col style="width: 10rem;" />
                  </colgroup>
                  <thead>
                    <tr>
                      <th>Issue</th>
                      <th>State</th>
                      <th>Session</th>
                      <th>Runtime / turns</th>
                      <th>Codex update</th>
                      <th>Tokens</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={entry <- @payload.running}>
                      <td>
                        <div class="issue-stack">
                          <span class="issue-id"><%= entry.issue_identifier %></span>
                          <a class="issue-link" href={"/issues/#{entry.issue_identifier}"}>Issue workspace</a>
                        </div>
                      </td>
                      <td>
                        <span class={state_badge_class(entry.state)}>
                          <%= entry.state %>
                        </span>
                      </td>
                      <td>
                        <div class="session-stack">
                          <%= if entry.session_id do %>
                            <button
                              type="button"
                              class="subtle-button"
                              data-label="Copy ID"
                              data-copy={entry.session_id}
                              onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                            >
                              Copy ID
                            </button>
                          <% else %>
                            <span class="muted">n/a</span>
                          <% end %>
                        </div>
                      </td>
                      <td class="numeric"><%= format_runtime_and_turns(entry.started_at, entry.turn_count, @now) %></td>
                      <td>
                        <div class="detail-stack">
                          <span
                            class="event-text"
                            title={entry.last_message || to_string(entry.last_event || "n/a")}
                          ><%= entry.last_message || to_string(entry.last_event || "n/a") %></span>
                          <span class="muted event-meta">
                            <%= entry.last_event || "n/a" %>
                            <%= if entry.last_event_at do %>
                              · <span class="mono numeric"><%= entry.last_event_at %></span>
                            <% end %>
                          </span>
                        </div>
                      </td>
                      <td>
                        <div class="token-stack numeric">
                          <span>Total: <%= format_int(entry.tokens.total_tokens) %></span>
                          <span class="muted">In <%= format_int(entry.tokens.input_tokens) %> / Out <%= format_int(entry.tokens.output_tokens) %></span>
                        </div>
                      </td>
                    </tr>
                  </tbody>
                </table>
              </div>
            <% end %>
          </section>

          <section class="section-card">
            <div class="section-header">
              <div>
                <h2 class="section-title">Retry queue</h2>
                <p class="section-copy">Issues waiting for the next retry window.</p>
              </div>
            </div>

            <%= if @payload.retrying == [] do %>
              <div class="empty-state-panel">
                <strong>Backoff clear</strong>
                <p class="empty-state">
                  No issues are currently backing off. Retries will land here only when a lane enters recovery.
                </p>
              </div>
            <% else %>
              <div class="table-wrap">
                <table class="data-table" style="min-width: 680px;">
                  <thead>
                    <tr>
                      <th>Issue</th>
                      <th>Attempt</th>
                      <th>Due at</th>
                      <th>Error</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={entry <- @payload.retrying}>
                      <td>
                        <div class="issue-stack">
                          <span class="issue-id"><%= entry.issue_identifier %></span>
                          <a class="issue-link" href={"/issues/#{entry.issue_identifier}"}>Issue workspace</a>
                        </div>
                      </td>
                      <td><%= entry.attempt %></td>
                      <td class="mono"><%= entry.due_at || "n/a" %></td>
                      <td><%= entry.error || "n/a" %></td>
                    </tr>
                  </tbody>
                </table>
              </div>
            <% end %>
          </section>
        <% end %>
      </section>
    </Layouts.dashboard_frame>
    """
  end

  defp load_payload do
    Presenter.state_payload(orchestrator(), snapshot_timeout_ms())
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end

  defp sidebar_counts(%{error: _}), do: nil
  defp sidebar_counts(payload), do: Map.get(payload, :counts)

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
    normalized = state |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["progress", "running", "active"]) -> "#{base} state-badge-active"
      String.contains?(normalized, ["blocked", "error", "failed"]) -> "#{base} state-badge-danger"
      String.contains?(normalized, ["todo", "queued", "pending", "retry"]) -> "#{base} state-badge-warning"
      true -> base
    end
  end
end
