defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Symphony.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.{Config, Tracker.Local}
  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}
  @runtime_tick_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:payload, load_payload())
      |> assign(:local_issue_states, local_issue_states())
      |> assign(:local_tracker_feedback, nil)
      |> assign(:selected_local_issue_ref, nil)
      |> assign(:now, DateTime.utc_now())
      |> refresh_local_tracker()

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
     |> assign(:now, DateTime.utc_now())
     |> refresh_local_tracker()}
  end

  @impl true
  def handle_event("create_local_issue", %{"issue" => params}, socket) do
    case Local.create_issue(local_issue_attrs(params)) do
      {:ok, issue} ->
        ObservabilityPubSub.broadcast_update()

        {:noreply,
         socket
         |> assign(:local_tracker_feedback, %{
           kind: :info,
           message: "Created #{issue.identifier}"
         })
         |> refresh_local_tracker(issue.id || issue.identifier)}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:local_tracker_feedback, %{
           kind: :error,
           message: local_tracker_error_message("Failed to create local issue", reason)
         })
         |> refresh_local_tracker()}
    end
  end

  def handle_event(
        "update_local_issue_state",
        %{"issue_ref" => issue_ref, "state" => state},
        socket
      ) do
    case Local.update_issue_state(issue_ref, state) do
      :ok ->
        ObservabilityPubSub.broadcast_update()

        {:noreply,
         socket
         |> assign(:local_tracker_feedback, %{
           kind: :info,
           message: "Updated #{issue_ref} to #{state}"
         })
         |> refresh_local_tracker(issue_ref)}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:local_tracker_feedback, %{
           kind: :error,
           message: local_tracker_error_message("Failed to update local issue state", reason)
         })
         |> refresh_local_tracker(issue_ref)}
    end
  end

  def handle_event("select_local_issue", %{"issue_ref" => issue_ref}, socket) do
    {:noreply, refresh_local_tracker(socket, issue_ref)}
  end

  def handle_event("release_local_issue_lease", %{"issue_ref" => issue_ref}, socket) do
    case Local.release_issue_claim(issue_ref) do
      :ok ->
        ObservabilityPubSub.broadcast_update()

        {:noreply,
         socket
         |> assign(:local_tracker_feedback, %{
           kind: :info,
           message: "Released lease on #{issue_ref}"
         })
         |> refresh_local_tracker(issue_ref)}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:local_tracker_feedback, %{
           kind: :error,
           message: local_tracker_error_message("Failed to release local issue lease", reason)
         })
         |> refresh_local_tracker(issue_ref)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">
              Symphony Observability
            </p>
            <h1 class="hero-title">
              Operations Dashboard
            </h1>
            <p class="hero-copy">
              Current state, retry pressure, token usage, and orchestration health for the active Symphony runtime.
            </p>
          </div>

          <div class="status-stack">
            <span class="status-badge status-badge-live">
              <span class="status-badge-dot"></span>
              Live
            </span>
            <span class="status-badge status-badge-offline">
              <span class="status-badge-dot"></span>
              Offline
            </span>
          </div>
        </div>
      </header>

      <%= if @payload[:error] do %>
        <section class="error-card">
          <h2 class="error-title">
            Snapshot unavailable
          </h2>
          <p class="error-copy">
            <strong><%= @payload.error.code %>:</strong> <%= @payload.error.message %>
          </p>
        </section>
      <% else %>
        <section class="metric-grid">
          <article class="metric-card">
            <p class="metric-label">Running</p>
            <p class="metric-value numeric"><%= @payload.counts.running %></p>
            <p class="metric-detail">Active issue sessions in the current runtime.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Retrying</p>
            <p class="metric-value numeric"><%= @payload.counts.retrying %></p>
            <p class="metric-detail">Issues waiting for the next retry window.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Total tokens</p>
            <p class="metric-value numeric"><%= format_int(@payload.codex_totals.total_tokens) %></p>
            <p class="metric-detail numeric">
              In <%= format_int(@payload.codex_totals.input_tokens) %> / Out <%= format_int(@payload.codex_totals.output_tokens) %>
            </p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Runtime</p>
            <p class="metric-value numeric"><%= format_runtime_seconds(total_runtime_seconds(@payload, @now)) %></p>
            <p class="metric-detail">Total Codex runtime across completed and active sessions.</p>
          </article>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Rate limits</h2>
              <p class="section-copy">Latest upstream rate-limit snapshot, when available.</p>
            </div>
          </div>

          <pre class="code-panel"><%= pretty_value(@payload.rate_limits) %></pre>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Running sessions</h2>
              <p class="section-copy">Active issues, last known agent activity, and token usage.</p>
            </div>
          </div>

          <%= if @payload.running == [] do %>
            <p class="empty-state">No active sessions.</p>
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
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
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
            <p class="empty-state">No issues are currently backing off.</p>
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
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
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

        <section :if={@local_tracker.enabled?} class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Local issues</h2>
              <p class="section-copy">
                Create and move local tracker issues without leaving the dashboard.
              </p>
            </div>

            <div class="tracker-meta">
              <span class="state-badge state-badge-active">local</span>
              <span class="mono tracker-path"><%= @local_tracker.path || "n/a" %></span>
            </div>
          </div>

          <%= if @local_tracker_feedback do %>
            <p class={tracker_feedback_class(@local_tracker_feedback.kind)}>
              <%= @local_tracker_feedback.message %>
            </p>
          <% end %>

          <%= if @local_tracker.error do %>
            <p class="tracker-feedback tracker-feedback-error">
              <%= @local_tracker.error %>
            </p>
          <% end %>

          <div class="tracker-grid">
            <div>
              <div class="tracker-summary-grid">
                <article class="tracker-summary-card">
                  <p class="metric-label">Agent Capacity</p>
                  <p class="metric-value"><%= local_tracker_capacity_value(@payload) %></p>
                  <p class="metric-detail"><%= local_tracker_capacity_detail(@payload) %></p>
                </article>

                <article class="tracker-summary-card">
                  <p class="metric-label">In Progress</p>
                  <p class="metric-value"><%= local_issue_count(@local_tracker, ["In Progress"]) %></p>
                  <p class="metric-detail">Current parallel work owned by the local tracker.</p>
                </article>

                <article class="tracker-summary-card">
                  <p class="metric-label">Runnable</p>
                  <p class="metric-value"><%= local_runnable_issue_count(@local_tracker) %></p>
                  <p class="metric-detail">Queued slices that are not actively leased by another runtime.</p>
                </article>

                <article class="tracker-summary-card">
                  <p class="metric-label">Running Sessions</p>
                  <p class="metric-value"><%= local_tracker_runtime_count(@local_tracker, @payload, :running) %></p>
                  <p class="metric-detail">Issue runs currently attached to live agents.</p>
                </article>

                <article class="tracker-summary-card">
                  <p class="metric-label">Retrying</p>
                  <p class="metric-value"><%= local_tracker_runtime_count(@local_tracker, @payload, :retrying) %></p>
                  <p class="metric-detail">Issues waiting out a retry backoff after a failed attempt.</p>
                </article>
              </div>

              <%= if @local_tracker.issues == [] do %>
                <p class="empty-state">No local issues yet. Create one to start a new run.</p>
              <% else %>
                <div class="table-wrap">
                  <table class="data-table" style="min-width: 920px;">
                    <thead>
                      <tr>
                        <th>Issue</th>
                        <th>Runtime</th>
                        <th>State</th>
                        <th>Priority</th>
                        <th>Labels</th>
                        <th>Updated</th>
                        <th>Focus</th>
                        <th>Move</th>
                      </tr>
                    </thead>
                    <tbody>
                      <tr :for={issue <- @local_tracker.issues} class={local_issue_row_class(issue, @selected_local_issue_ref)}>
                        <td>
                          <div class="issue-stack">
                            <span class="issue-id"><%= issue.identifier %></span>
                            <span><%= issue.title %></span>
                            <span :if={issue.description} class="muted"><%= issue.description %></span>
                          </div>
                        </td>
                        <td>
                          <span class={local_issue_runtime_badge_class(issue, @payload)}>
                            <%= local_issue_runtime_badge(issue, @payload) %>
                          </span>
                        </td>
                        <td>
                          <span class={state_badge_class(issue.state)}>
                            <%= issue.state %>
                          </span>
                        </td>
                        <td class="numeric"><%= local_issue_priority(issue.priority) %></td>
                        <td><%= local_issue_labels(issue.labels) %></td>
                        <td class="mono"><%= issue.updated_at || "n/a" %></td>
                        <td>
                          <button
                            type="button"
                            class="secondary tracker-focus-button"
                            phx-click="select_local_issue"
                            phx-value-issue_ref={issue.id}
                          >
                            Focus
                          </button>
                        </td>
                        <td>
                          <form
                            id={"local-issue-state-#{issue.id}"}
                            class="issue-state-form"
                            phx-submit="update_local_issue_state"
                          >
                            <input type="hidden" name="issue_ref" value={issue.id} />
                            <select name="state">
                              <option
                                :for={state <- @local_issue_states}
                                selected={state == issue.state}
                                value={state}
                              >
                                <%= state %>
                              </option>
                            </select>
                            <button type="submit" class="secondary">Set</button>
                          </form>
                        </td>
                      </tr>
                    </tbody>
                  </table>
                </div>
              <% end %>
            </div>

            <div class="tracker-sidebar">
              <article class="tracker-detail-card">
                <%= if issue = selected_local_issue(@local_tracker, @selected_local_issue_ref) do %>
                  <% runtime = local_issue_runtime_details(issue, @payload) %>
                  <div class="tracker-detail-header">
                    <div class="issue-stack">
                      <span class="issue-id"><%= issue.identifier %></span>
                      <strong><%= issue.title %></strong>
                    </div>

                    <a class="issue-link" href={local_issue_detail_href(issue)}>
                      JSON details
                    </a>
                  </div>

                  <div class="tracker-pill-row">
                    <span class={state_badge_class(issue.state)}><%= issue.state %></span>
                    <span class={local_issue_runtime_badge_class(issue, @payload)}>
                      <%= local_issue_runtime_badge(issue, @payload) %>
                    </span>
                  </div>

                  <dl class="tracker-detail-list">
                    <div>
                      <dt>Priority</dt>
                      <dd><%= local_issue_priority(issue.priority) %></dd>
                    </div>
                    <div>
                      <dt>Labels</dt>
                      <dd><%= local_issue_labels(issue.labels) %></dd>
                    </div>
                    <div>
                      <dt>Updated</dt>
                      <dd class="mono"><%= issue.updated_at || "n/a" %></dd>
                    </div>
                    <div>
                      <dt>Created</dt>
                      <dd class="mono"><%= issue.created_at || "n/a" %></dd>
                    </div>
                    <div>
                      <dt>Branch</dt>
                      <dd class="mono"><%= issue.branch_name || "n/a" %></dd>
                    </div>
                    <div>
                      <dt>Worker Eligible</dt>
                      <dd><%= local_issue_worker_label(issue.assigned_to_worker) %></dd>
                    </div>
                    <div>
                      <dt>Claimed By</dt>
                      <dd class="mono"><%= issue.claimed_by || "unclaimed" %></dd>
                    </div>
                    <div>
                      <dt>Lease Status</dt>
                      <dd><%= local_issue_lease_label(issue) %></dd>
                    </div>
                    <div>
                      <dt>Claimed At</dt>
                      <dd class="mono"><%= issue.claimed_at || "n/a" %></dd>
                    </div>
                    <div>
                      <dt>Lease Expires</dt>
                      <dd class="mono"><%= issue.lease_expires_at || "n/a" %></dd>
                    </div>
                    <div>
                      <dt>Source</dt>
                      <dd>
                        <%= if issue.url do %>
                          <a class="issue-link" href={issue.url} target="_blank" rel="noreferrer">
                            Open linked item
                          </a>
                        <% else %>
                          n/a
                        <% end %>
                      </dd>
                    </div>
                    <div>
                      <dt>Blocked By</dt>
                      <dd><%= local_issue_blocked_by(issue.blocked_by) %></dd>
                    </div>
                  </dl>

                  <form
                    :if={local_issue_release_available?(issue)}
                    id={"local-issue-release-#{issue.id}"}
                    phx-submit="release_local_issue_lease"
                  >
                    <input type="hidden" name="issue_ref" value={issue.id} />
                    <button type="submit" class="secondary">Release Lease</button>
                  </form>

                  <div class="tracker-runtime-card">
                    <p class="metric-label">Runtime Details</p>
                    <dl class="tracker-detail-list tracker-runtime-list">
                      <div>
                        <dt>Workspace</dt>
                        <dd class="mono"><%= runtime.workspace_path %></dd>
                      </div>
                      <div>
                        <dt>Session</dt>
                        <dd class="mono"><%= runtime.session_id || "n/a" %></dd>
                      </div>
                      <div>
                        <dt>Turns</dt>
                        <dd><%= runtime.turn_count || 0 %></dd>
                      </div>
                      <div>
                        <dt>Last Event</dt>
                        <dd><%= runtime.last_event || "n/a" %></dd>
                      </div>
                      <div>
                        <dt>Last Update</dt>
                        <dd class="mono"><%= runtime.last_event_at || "n/a" %></dd>
                      </div>
                      <div>
                        <dt>Retry Due</dt>
                        <dd class="mono"><%= runtime.retry_due_at || "n/a" %></dd>
                      </div>
                    </dl>

                    <div :if={runtime.last_message} class="tracker-runtime-note">
                      <p class="metric-label">Latest Agent Note</p>
                      <pre><%= runtime.last_message %></pre>
                    </div>

                    <div :if={runtime.retry_error} class="tracker-runtime-note tracker-runtime-note-error">
                      <p class="metric-label">Last Error</p>
                      <pre><%= runtime.retry_error %></pre>
                    </div>
                  </div>

                  <div class="tracker-runtime-card">
                    <p class="metric-label">Local Comments</p>

                    <%= if issue.comments == [] do %>
                      <p class="empty-state">No local comments yet.</p>
                    <% else %>
                      <div :for={comment <- issue.comments} class="tracker-runtime-note">
                        <p class="metric-label"><%= comment.created_at || "timestamp unavailable" %></p>
                        <pre><%= comment.body %></pre>
                      </div>
                    <% end %>
                  </div>

                  <div :if={issue.description} class="code-panel">
                    <pre><%= issue.description %></pre>
                  </div>
                <% else %>
                  <p class="empty-state">Select an issue to inspect its local tracker details.</p>
                <% end %>
              </article>

              <form id="local-issue-create-form" class="tracker-create-form" phx-submit="create_local_issue">
                <div class="field-stack">
                  <label for="local-issue-title">Title</label>
                  <input id="local-issue-title" type="text" name="issue[title]" required />
                </div>

                <div class="field-row">
                  <div class="field-stack">
                    <label for="local-issue-state">State</label>
                    <select id="local-issue-state" name="issue[state]">
                      <option :for={state <- @local_issue_states} value={state}>
                        <%= state %>
                      </option>
                    </select>
                  </div>

                  <div class="field-stack">
                    <label for="local-issue-priority">Priority</label>
                    <input
                      id="local-issue-priority"
                      type="number"
                      min="0"
                      step="1"
                      name="issue[priority]"
                      placeholder="1"
                    />
                  </div>
                </div>

                <div class="field-stack">
                  <label for="local-issue-labels">Labels</label>
                  <input
                    id="local-issue-labels"
                    type="text"
                    name="issue[labels]"
                    placeholder="go, migration, local"
                  />
                </div>

                <div class="field-stack">
                  <label for="local-issue-description">Description</label>
                  <textarea
                    id="local-issue-description"
                    name="issue[description]"
                    rows="5"
                    placeholder="Describe the scope, acceptance checks, and any blockers."
                  ></textarea>
                </div>

                <button type="submit">Create issue</button>
              </form>
            </div>
          </div>
        </section>
      <% end %>
    </section>
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

  defp completed_runtime_seconds(payload) do
    payload.codex_totals.seconds_running || 0
  end

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

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end

  defp refresh_local_tracker(socket, selected_ref \\ nil) do
    tracker = load_local_tracker()
    selected_ref = resolve_selected_local_issue_ref(tracker, selected_ref || socket.assigns[:selected_local_issue_ref])

    socket
    |> assign(:local_tracker, tracker)
    |> assign(:selected_local_issue_ref, selected_ref)
  end

  defp load_local_tracker do
    case Config.tracker_kind() do
      "local" ->
        case Local.list_issues() do
          {:ok, issues} ->
            %{
              enabled?: true,
              path: Config.local_tracker_path(),
              issues: issues |> Enum.map(&local_issue_payload/1) |> sort_local_issues(),
              error: nil
            }

          {:error, reason} ->
            %{
              enabled?: true,
              path: Config.local_tracker_path(),
              issues: [],
              error: local_tracker_error_message("Failed to load local issue store", reason)
            }
        end

      _kind ->
        %{enabled?: false, path: nil, issues: [], error: nil}
    end
  end

  defp local_issue_payload(issue) do
    %{
      id: issue.id || issue.identifier,
      identifier: issue.identifier || issue.id || "LOCAL",
      title: issue.title || "Untitled issue",
      description: issue.description,
      state: issue.state || "Unknown",
      priority: issue.priority,
      labels: issue.labels || [],
      created_at: local_issue_timestamp(issue.created_at),
      updated_at: local_issue_timestamp(issue.updated_at),
      branch_name: issue.branch_name,
      blocked_by: issue.blocked_by || [],
      url: issue.url,
      assigned_to_worker: Map.get(issue, :assigned_to_worker, true),
      claimed_by: issue.claimed_by,
      claimed_at: local_issue_timestamp(issue.claimed_at),
      lease_expires_at: local_issue_timestamp(issue.lease_expires_at),
      lease_status: issue |> Local.lease_status() |> Atom.to_string(),
      comments: local_issue_comments(Map.get(issue, :comments, []))
    }
  end

  defp local_issue_attrs(params) when is_map(params) do
    params
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Enum.map(fn
      {"labels", value} -> {"labels", String.split(value, ",", trim: true)}
      {"priority", value} -> {"priority", parse_optional_integer(value)}
      entry -> entry
    end)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp parse_optional_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} -> integer
      _ -> nil
    end
  end

  defp parse_optional_integer(value) when is_integer(value), do: value
  defp parse_optional_integer(_value), do: nil

  defp local_issue_states do
    (["Backlog"] ++ Config.linear_active_states() ++ Config.linear_terminal_states())
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> case do
      [] -> ["Todo", "In Progress", "Done"]
      states -> states
    end
  end

  defp local_issue_timestamp(nil), do: nil

  defp local_issue_timestamp(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp local_issue_timestamp(value), do: to_string(value)

  defp local_issue_priority(nil), do: "n/a"
  defp local_issue_priority(priority), do: Integer.to_string(priority)

  defp local_issue_labels([]), do: "n/a"
  defp local_issue_labels(labels), do: Enum.join(labels, ", ")

  defp local_issue_worker_label(false), do: "manual only"
  defp local_issue_worker_label(_value), do: "worker enabled"

  defp local_issue_blocked_by([]), do: "none"
  defp local_issue_blocked_by(values), do: Enum.join(values, ", ")

  defp local_issue_comments(comments) when is_list(comments) do
    Enum.map(comments, fn comment ->
      %{
        body: Map.get(comment, :body),
        created_at: local_issue_timestamp(Map.get(comment, :created_at))
      }
    end)
  end

  defp local_issue_comments(_comments), do: []

  defp local_issue_count(tracker, states) when is_list(states) do
    wanted =
      states
      |> Enum.map(&normalize_issue_state/1)
      |> MapSet.new()

    Enum.count(tracker.issues, fn issue ->
      MapSet.member?(wanted, normalize_issue_state(issue.state))
    end)
  end

  defp local_runnable_issue_count(tracker) do
    wanted =
      ["Todo", "Rework"]
      |> Enum.map(&normalize_issue_state/1)
      |> MapSet.new()

    Enum.count(tracker.issues, fn issue ->
      MapSet.member?(wanted, normalize_issue_state(issue.state)) and
        local_issue_lease_status(issue) != "active"
    end)
  end

  defp local_tracker_runtime_count(tracker, payload, :running) do
    issue_refs = tracker_issue_identifiers(tracker)

    Enum.count(payload.running, fn entry ->
      MapSet.member?(issue_refs, Map.get(entry, :issue_identifier))
    end)
  end

  defp local_tracker_runtime_count(tracker, payload, :retrying) do
    issue_refs = tracker_issue_identifiers(tracker)

    Enum.count(payload.retrying, fn entry ->
      MapSet.member?(issue_refs, Map.get(entry, :issue_identifier))
    end)
  end

  defp tracker_issue_identifiers(tracker) do
    tracker.issues
    |> Enum.map(& &1.identifier)
    |> MapSet.new()
  end

  defp selected_local_issue(tracker, ref) do
    Enum.find(tracker.issues, &(&1.id == ref))
  end

  defp local_tracker_capacity_value(payload) do
    capacity = Map.get(payload, :capacity, %{})
    "#{Map.get(capacity, :running, 0)} / #{Map.get(capacity, :limit, 0)}"
  end

  defp local_tracker_capacity_detail(payload) do
    capacity = Map.get(payload, :capacity, %{})
    polling = Map.get(payload, :polling, %{})
    available = Map.get(capacity, :available, 0)

    poll_copy =
      cond do
        Map.get(polling, :checking?) -> "polling now"
        is_integer(Map.get(polling, :next_poll_in_ms)) -> "next poll #{format_runtime_seconds(ceil_seconds(Map.get(polling, :next_poll_in_ms)))}"
        true -> "poll schedule unavailable"
      end

    "#{available} open slots · #{poll_copy}"
  end

  defp ceil_seconds(milliseconds) when is_integer(milliseconds) and milliseconds > 0 do
    div(milliseconds + 999, 1_000)
  end

  defp ceil_seconds(_milliseconds), do: 0

  defp resolve_selected_local_issue_ref(%{issues: issues}, current_ref) do
    cond do
      Enum.any?(issues, &(&1.id == current_ref)) ->
        current_ref

      issue = Enum.find(issues, &(normalize_issue_state(&1.state) == normalize_issue_state("In Progress"))) ->
        issue.id

      issue = List.first(issues) ->
        issue.id

      true ->
        nil
    end
  end

  defp local_issue_runtime_badge(issue, payload) do
    cond do
      local_issue_retrying?(issue, payload) -> "Retrying"
      local_issue_running?(issue, payload) -> "Running"
      local_issue_lease_status(issue) == "active" -> "Leased"
      local_issue_lease_status(issue) == "expired" -> "Lease Expired"
      true -> "Idle"
    end
  end

  defp local_issue_runtime_badge_class(issue, payload) do
    base = "state-badge"

    cond do
      local_issue_retrying?(issue, payload) -> "#{base} state-badge-danger"
      local_issue_running?(issue, payload) -> "#{base} state-badge-active"
      local_issue_lease_status(issue) == "active" -> "#{base} state-badge-warning"
      local_issue_lease_status(issue) == "expired" -> "#{base} state-badge-danger"
      true -> base
    end
  end

  defp local_issue_lease_status(issue) do
    Map.get(issue, :lease_status) || "unclaimed"
  end

  defp local_issue_lease_label(issue) do
    case local_issue_lease_status(issue) do
      "active" -> "active"
      "expired" -> "expired"
      _ -> "unclaimed"
    end
  end

  defp local_issue_release_available?(issue), do: local_issue_lease_status(issue) != "unclaimed"

  defp local_issue_running?(issue, payload) do
    Enum.any?(payload.running, fn entry ->
      Map.get(entry, :issue_identifier) == issue.identifier
    end)
  end

  defp local_issue_retrying?(issue, payload) do
    Enum.any?(payload.retrying, fn entry ->
      Map.get(entry, :issue_identifier) == issue.identifier
    end)
  end

  defp local_issue_runtime_details(issue, payload) do
    running = local_issue_running_entry(issue, payload)
    retry = local_issue_retry_entry(issue, payload)

    %{
      workspace_path: Path.join(Config.workspace_root(), issue.identifier),
      session_id: running && Map.get(running, :session_id),
      turn_count: running && Map.get(running, :turn_count),
      last_event: running && Map.get(running, :last_event),
      last_message: running && Map.get(running, :last_message),
      last_event_at: running && Map.get(running, :last_event_at),
      retry_due_at: retry && Map.get(retry, :due_at),
      retry_error: retry && Map.get(retry, :error)
    }
  end

  defp local_issue_running_entry(issue, payload) do
    Enum.find(payload.running, fn entry ->
      Map.get(entry, :issue_identifier) == issue.identifier
    end)
  end

  defp local_issue_retry_entry(issue, payload) do
    Enum.find(payload.retrying, fn entry ->
      Map.get(entry, :issue_identifier) == issue.identifier
    end)
  end

  defp local_issue_detail_href(issue), do: "/api/v1/#{issue.identifier}"

  defp local_issue_row_class(issue, selected_ref) when issue.id == selected_ref,
    do: "issue-row-selected"

  defp local_issue_row_class(_issue, _selected_ref), do: nil

  defp sort_local_issues(issues) do
    Enum.sort_by(issues, fn issue ->
      {
        local_issue_state_rank(issue.state),
        issue.priority || 9_999,
        issue.identifier
      }
    end)
  end

  defp local_issue_state_rank(state) do
    case normalize_issue_state(state) do
      "in progress" -> 0
      "rework" -> 1
      "todo" -> 2
      "in review" -> 3
      "merging" -> 4
      "backlog" -> 5
      _ -> 6
    end
  end

  defp tracker_feedback_class(:error), do: "tracker-feedback tracker-feedback-error"
  defp tracker_feedback_class(_kind), do: "tracker-feedback tracker-feedback-info"

  defp local_tracker_error_message(prefix, :issue_not_found), do: "#{prefix}: issue not found"
  defp local_tracker_error_message(prefix, reason), do: "#{prefix}: #{inspect(reason)}"

  defp normalize_issue_state(state) when is_binary(state) do
    state
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_issue_state(state), do: state |> to_string() |> normalize_issue_state()

  defp pretty_value(nil), do: "n/a"
  defp pretty_value(value), do: inspect(value, pretty: true, limit: :infinity)
end
