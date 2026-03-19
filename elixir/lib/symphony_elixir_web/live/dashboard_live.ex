defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Symphony.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.{Config, Tracker.Local}
  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}
  @runtime_tick_ms 1_000
  @issue_upload_max_entries 6
  @issue_upload_max_file_size 20_000_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> allow_upload(:issue_files,
        accept: :any,
        max_entries: @issue_upload_max_entries,
        max_file_size: @issue_upload_max_file_size
      )
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
    case store_uploaded_attachments(socket) do
      {:ok, attachments} ->
        case Local.create_issue(local_issue_attrs(params, attachments)) do
          {:ok, issue} ->
            ObservabilityPubSub.broadcast_update()

            {:noreply,
             socket
             |> assign(:local_tracker_feedback, %{
               kind: :info,
               message: created_issue_feedback(issue, attachments)
             })
             |> refresh_local_tracker(issue.id || issue.identifier)}

          {:error, reason} ->
            discard_stored_attachments(attachments)

            {:noreply,
             socket
             |> assign(:local_tracker_feedback, %{
               kind: :error,
               message: local_tracker_error_message("Failed to create local issue", reason)
             })
             |> refresh_local_tracker()}
        end

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
                  <p class="metric-value"><%= local_issue_count(@local_tracker, ["Todo", "Rework"]) %></p>
                  <p class="metric-detail">Queued slices that can be picked up next.</p>
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

                  <div class="tracker-attachment-card">
                    <div class="tracker-attachment-header">
                      <p class="metric-label">Issue Files</p>
                      <span class="muted"><%= local_issue_attachment_summary(issue.attachments) %></span>
                    </div>

                    <%= if issue.attachments == [] do %>
                      <p class="empty-state">No files uploaded for this issue yet.</p>
                    <% else %>
                      <div class="tracker-attachment-list">
                        <article :for={attachment <- issue.attachments} class="tracker-attachment-item">
                          <div class="tracker-attachment-copy">
                            <strong><%= attachment.filename %></strong>
                            <span class="muted">
                              <%= local_issue_attachment_meta(attachment) %>
                            </span>
                          </div>

                          <a class="secondary tracker-attachment-link" href={attachment.download_path}>
                            Download
                          </a>
                        </article>
                      </div>
                    <% end %>
                  </div>

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

                <div class="field-stack">
                  <label for="local-issue-files">Issue Files</label>
                  <div class="upload-panel" phx-drop-target={@uploads.issue_files.ref}>
                    <.live_file_input id="local-issue-files" upload={@uploads.issue_files} />
                    <p class="upload-copy">
                      Upload specs, screenshots, or implementation notes directly into the local tracker.
                    </p>
                    <p class="upload-hint">
                      Up to <%= issue_upload_max_entries() %> files, <%= format_bytes(issue_upload_max_file_size()) %> each.
                    </p>
                  </div>

                  <%= for err <- upload_errors(@uploads.issue_files) do %>
                    <p class="tracker-feedback tracker-feedback-error"><%= upload_error_message(err) %></p>
                  <% end %>

                  <div :if={@uploads.issue_files.entries != []} class="upload-entry-list">
                    <%= for entry <- @uploads.issue_files.entries do %>
                      <article class="upload-entry">
                        <div class="tracker-attachment-copy">
                          <strong><%= entry.client_name %></strong>
                          <span class="muted"><%= format_bytes(entry.client_size) %></span>
                        </div>
                        <span class="muted"><%= entry.progress %>%</span>
                      </article>

                      <%= for err <- upload_errors(@uploads.issue_files, entry) do %>
                        <p class="tracker-feedback tracker-feedback-error"><%= upload_error_message(err) %></p>
                      <% end %>
                    <% end %>
                  </div>
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

  defp issue_upload_max_entries, do: @issue_upload_max_entries
  defp issue_upload_max_file_size, do: @issue_upload_max_file_size

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
      attachments:
        issue
        |> Map.get(:attachments, [])
        |> Enum.map(&local_issue_attachment_payload(&1, issue)),
      url: issue.url,
      assigned_to_worker: Map.get(issue, :assigned_to_worker, true),
      claimed_by: issue.claimed_by,
      claimed_at: local_issue_timestamp(issue.claimed_at),
      lease_expires_at: local_issue_timestamp(issue.lease_expires_at)
    }
  end

  defp local_issue_attrs(params, attachments) when is_map(params) and is_list(attachments) do
    params
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Enum.map(fn
      {"labels", value} -> {"labels", String.split(value, ",", trim: true)}
      {"priority", value} -> {"priority", parse_optional_integer(value)}
      entry -> entry
    end)
    |> Kernel.++([{"attachments", attachments}])
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

  defp local_issue_attachment_payload(attachment, issue) when is_map(attachment) do
    %{
      id: attachment["id"],
      filename: attachment["filename"] || "attachment",
      content_type: attachment["content_type"],
      byte_size: attachment["byte_size"],
      uploaded_at: attachment["uploaded_at"],
      download_path: local_issue_attachment_download_path(issue, attachment)
    }
  end

  defp local_issue_attachment_download_path(issue, attachment) do
    issue_ref = issue.id || issue.identifier
    attachment_id = attachment["id"]

    if is_binary(issue_ref) and is_binary(attachment_id) do
      "/api/v1/local-issues/#{URI.encode(issue_ref)}/attachments/#{URI.encode(attachment_id)}"
    end
  end

  defp local_issue_attachment_summary([]), do: "0 files"

  defp local_issue_attachment_summary(attachments) when is_list(attachments) do
    count = length(attachments)
    total_bytes = Enum.reduce(attachments, 0, &(Map.get(&1, :byte_size, 0) + &2))
    "#{count} file#{if count == 1, do: "", else: "s"} · #{format_bytes(total_bytes)}"
  end

  defp local_issue_attachment_meta(attachment) do
    [attachment.content_type, format_bytes(attachment.byte_size), attachment.uploaded_at]
    |> Enum.reject(&nil_or_empty?/1)
    |> Enum.join(" · ")
  end

  defp format_bytes(value) when is_integer(value) and value >= 1_000_000_000,
    do: :io_lib.format("~.1f GB", [value / 1_000_000_000]) |> IO.iodata_to_binary()

  defp format_bytes(value) when is_integer(value) and value >= 1_000_000,
    do: :io_lib.format("~.1f MB", [value / 1_000_000]) |> IO.iodata_to_binary()

  defp format_bytes(value) when is_integer(value) and value >= 1_000,
    do: :io_lib.format("~.1f KB", [value / 1_000]) |> IO.iodata_to_binary()

  defp format_bytes(value) when is_integer(value) and value >= 0, do: "#{value} B"
  defp format_bytes(_value), do: "n/a"

  defp upload_error_message(:too_large), do: "One of the selected files exceeds the upload limit."
  defp upload_error_message(:too_many_files), do: "Too many files selected for a single issue."
  defp upload_error_message(:not_accepted), do: "A selected file type is not accepted."

  defp upload_error_message(:external_client_failure),
    do: "The browser failed to finish uploading one of the selected files."

  defp upload_error_message(other), do: "Upload failed: #{inspect(other)}"

  defp created_issue_feedback(issue, []) do
    "Created #{issue.identifier}"
  end

  defp created_issue_feedback(issue, attachments) do
    "Created #{issue.identifier} with #{length(attachments)} file#{if length(attachments) == 1, do: "", else: "s"}"
  end

  defp store_uploaded_attachments(socket) do
    upload = socket.assigns.uploads.issue_files

    if upload_has_errors?(upload) do
      {:error, :invalid_issue_attachments}
    else
      socket
      |> consume_issue_upload_entries()
      |> normalize_uploaded_attachments()
    end
  end

  defp consume_issue_upload_entries(socket) do
    consume_uploaded_entries(socket, :issue_files, fn %{path: path}, entry ->
      case Local.store_attachment(path, entry.client_name, entry.client_type) do
        {:ok, attachment} -> {:ok, {:ok, attachment}}
        {:error, reason} -> {:ok, {:error, reason}}
      end
    end)
  end

  defp normalize_uploaded_attachments(results) do
    case Enum.split_with(results, &match?({:ok, _attachment}, &1)) do
      {oks, []} ->
        {:ok, Enum.map(oks, fn {:ok, attachment} -> attachment end)}

      {oks, [{:error, reason} | _rest]} ->
        oks
        |> Enum.map(fn {:ok, attachment} -> attachment end)
        |> discard_stored_attachments()

        {:error, reason}
    end
  end

  defp upload_has_errors?(upload) do
    upload.errors != [] or Enum.any?(upload.entries, &(not &1.valid?))
  end

  defp discard_stored_attachments(attachments) do
    Enum.each(attachments, &Local.discard_attachment/1)
  end

  defp nil_or_empty?(value), do: value in [nil, ""]

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

  defp local_issue_count(tracker, states) when is_list(states) do
    wanted =
      states
      |> Enum.map(&normalize_issue_state/1)
      |> MapSet.new()

    Enum.count(tracker.issues, fn issue ->
      MapSet.member?(wanted, normalize_issue_state(issue.state))
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
      true -> "Idle"
    end
  end

  defp local_issue_runtime_badge_class(issue, payload) do
    base = "state-badge"

    cond do
      local_issue_retrying?(issue, payload) -> "#{base} state-badge-danger"
      local_issue_running?(issue, payload) -> "#{base} state-badge-active"
      true -> "#{base} state-badge-warning"
    end
  end

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
