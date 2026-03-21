defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Symphony.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.{Config, Tracker.Local}
  alias SymphonyElixirWeb.{Endpoint, Layouts, ObservabilityPubSub, Presenter}
  @runtime_tick_ms 1_000
  @issue_upload_max_entries 6

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> allow_upload(:issue_files,
        accept: Local.attachment_upload_accepts(),
        max_entries: @issue_upload_max_entries,
        max_file_size: Local.attachment_max_file_size()
      )
      |> assign(:payload, load_payload())
      |> assign(:local_issue_states, local_issue_states())
      |> assign(:local_issue_filters, default_local_issue_filters())
      |> assign(:local_issue_view_mode, "list")
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

  def handle_event("filter_local_issues", %{"filters" => filters}, socket) do
    {:noreply, assign(socket, :local_issue_filters, normalize_local_issue_filters(filters))}
  end

  def handle_event("set_local_issue_view", %{"mode" => mode}, socket) do
    {:noreply, assign(socket, :local_issue_view_mode, normalize_local_issue_view_mode(mode))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <% selected_issue = selected_local_issue(@local_tracker, @selected_local_issue_ref) %>
    <Layouts.dashboard_frame
      active_section="issues"
      counts={sidebar_counts(@payload)}
      issue_shortcut={sidebar_issue_shortcut(selected_issue)}
    >
    <section class="dashboard-shell">
      <header class="hero-card page-hero-card">
        <div class="page-hero-grid">
          <div class="page-hero-main">
            <p class="eyebrow">Issues</p>
            <h1 class="hero-title page-hero-title">Local Issue Studio</h1>
            <p class="hero-copy">
              Issue intake, local board routing, focused issue movement, and operator controls now live on a dedicated page with room to breathe.
            </p>

            <div class="hero-toolbar">
              <nav class="hero-section-nav" aria-label="Issue studio quick actions">
                <a class="hero-action-button" href="/">
                  <strong>Overview</strong>
                  <span>Runtime posture and capacity</span>
                </a>

                <a class="hero-action-button" href="/sessions">
                  <strong>Sessions</strong>
                  <span>Live execution lanes and retries</span>
                </a>

                <%= if selected_issue do %>
                  <a class="hero-action-button" href={local_issue_detail_href(selected_issue)}>
                    <strong>Focused workspace</strong>
                    <span><%= selected_issue.identifier %> deep-dive page</span>
                  </a>
                <% end %>
              </nav>

              <div class="hero-utility-row">
                <a
                  class="hero-utility-button"
                  href="/api/v1/state"
                  target="_blank"
                  rel="noreferrer"
                >
                  <strong>State API</strong>
                  <span>Open the raw dashboard snapshot</span>
                </a>
              </div>

              <p class="hero-toolbar-copy">
                Keep intake, focus, and movement together here, while full issue context stays one click away in the dedicated workspace page.
              </p>
            </div>

            <div class="page-hero-chip-grid">
              <article class="page-hero-chip">
                <span>Intake</span>
                <strong><%= if @local_tracker.enabled?, do: "Ready", else: "Offline" %></strong>
                <p class="page-hero-chip-copy">Local tracker issue intake with file attachments.</p>
              </article>

              <article class="page-hero-chip">
                <span>Issues</span>
                <strong><%= length(@local_tracker.issues) %></strong>
                <p class="page-hero-chip-copy">Open local tracker records visible from this board.</p>
              </article>

              <article class="page-hero-chip">
                <span>Focus</span>
                <strong><%= if selected_issue, do: selected_issue.identifier, else: "Select issue" %></strong>
                <p class="page-hero-chip-copy">Keep the current mission visible while routing work.</p>
              </article>
            </div>
          </div>

          <div class="page-hero-side">
            <article class="page-hero-side-card">
              <p class="metric-label">Tracker mode</p>
              <p class="page-hero-side-value"><%= if @local_tracker.enabled?, do: "local", else: "disabled" %></p>
              <p class="metric-detail"><%= @local_tracker.path || "No local tracker configured." %></p>
            </article>

            <article class="page-hero-side-card">
              <p class="metric-label">Focused issue</p>
              <p class="page-hero-side-value"><%= selected_issue && selected_issue.identifier || "n/a" %></p>
              <p class="metric-detail">
                <%= selected_issue && selected_issue.title || "Select an issue from the board to inspect it here." %>
              </p>
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
        <%= if @local_tracker.enabled? do %>
          <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Local issues</h2>
              <p class="section-copy">
                Create, search, and route local tracker issues here, then open a dedicated issue workspace for full details.
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

          <% filtered_local_issues = filtered_local_issues(@local_tracker, @local_issue_filters, @payload) %>
          <% board_columns = local_issue_board_columns(filtered_local_issues, @local_issue_states) %>

          <div class="tracker-studio">
            <section class="tracker-stage tracker-stage-intake">
              <div class="tracker-stage-header">
                <div>
                  <p class="eyebrow">Mission Intake</p>
                  <h3 class="tracker-stage-title">Create issue in the local tracker</h3>
                  <p class="tracker-stage-copy">
                    Open a new workstream, attach source material, and launch the next parallel slice without leaving the dashboard.
                  </p>
                </div>

                <div class="tracker-stage-meta">
                  <span class="state-badge state-badge-active">intake live</span>
                  <span class="muted">Repo-native issue intake for multi-agent execution.</span>
                </div>
              </div>

              <form id="local-issue-create-form" class="tracker-create-form tracker-create-form-top" phx-submit="create_local_issue">
                <div class="tracker-create-grid">
                  <section class="tracker-form-section">
                    <p class="tracker-form-section-title">Essentials</p>

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
                  </section>

                  <section class="tracker-form-section">
                    <p class="tracker-form-section-title">Context</p>

                    <div class="field-stack">
                      <label for="local-issue-description">Description</label>
                      <textarea
                        id="local-issue-description"
                        name="issue[description]"
                        rows="8"
                        placeholder="Describe the scope, acceptance checks, and any blockers."
                      ></textarea>
                    </div>
                  </section>

                  <section class="tracker-form-section">
                    <p class="tracker-form-section-title">Files</p>

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
                        <p class="upload-hint">
                          Accepted formats: <%= local_issue_attachment_accept_summary() %>
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
                  </section>
                </div>

                <div class="tracker-create-actions">
                  <button type="submit">Create local issue</button>
                </div>
              </form>
            </section>

            <section class="tracker-stage tracker-stage-ops">
              <div class="tracker-stage-header">
                <div>
                  <p class="eyebrow">Agent Parallel Studio</p>
                  <h3 class="tracker-stage-title">Agent capacity and focused mission board</h3>
                  <p class="tracker-stage-copy">
                    Keep capacity, active lanes, and the focused issue aligned in two parallel columns while agents split work, retry, and converge on delivery.
                  </p>
                </div>

                <div class="tracker-stage-meta">
                  <span class="metric-detail">
                    <%= length(@local_tracker.issues) %> total issues · <%= local_tracker_runtime_count(@local_tracker, @payload, :running) %> live runs
                  </span>
                </div>
              </div>

              <div class="tracker-ops-grid">
                <article class="tracker-detail-card tracker-detail-card-ops tracker-ops-panel">
                  <div class="tracker-detail-intro">
                    <p class="eyebrow">Agent Parallel Studio</p>

                    <div class="tracker-detail-header">
                      <div class="issue-stack">
                        <strong>Parallel agents, shared visibility</strong>
                        <span class="muted">
                          Capacity, runnable slices, and live sessions stay aligned with the focused issue for fast left-to-right scanning.
                        </span>
                      </div>

                      <span class="metric-detail">
                        <%= length(@local_tracker.issues) %> total issues · <%= local_tracker_runtime_count(@local_tracker, @payload, :running) %> live runs
                      </span>
                    </div>
                  </div>

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

                  <div class="tracker-runtime-card tracker-runtime-card-compact">
                    <p class="metric-label">Studio Brief</p>
                    <p class="tracker-form-copy">
                      Intake stays on top, the studio and focused issue stay aligned in the middle, and search plus movement controls stay compact at the bottom so operators always know what to launch, inspect, and move next.
                    </p>
                  </div>
                </article>

                <article class="tracker-detail-card tracker-detail-card-ops tracker-spotlight-card">
                <%= if issue = selected_local_issue(@local_tracker, @selected_local_issue_ref) do %>
                  <% runtime = local_issue_runtime_details(issue, @payload) %>
                  <div class="tracker-focus-header">
                    <div class="tracker-focus-copy">
                      <p class="eyebrow">Focused issue snapshot</p>

                      <div class="tracker-focus-badges">
                        <span class="issue-id"><%= issue.identifier %></span>
                        <span class={state_badge_class(issue.state)}><%= issue.state %></span>
                        <span class={local_issue_runtime_badge_class(issue, @payload)}>
                          <%= local_issue_runtime_badge(issue, @payload) %>
                        </span>
                      </div>

                      <h4 class="tracker-focus-title"><%= issue.title %></h4>
                      <p :if={issue.description} class="tracker-focus-summary"><%= issue.description %></p>
                    </div>

                    <div class="tracker-focus-actions">
                      <a class="tracker-link-button" href={local_issue_detail_href(issue)}>
                        Open issue page
                      </a>

                      <form
                        :if={local_issue_release_available?(issue)}
                        id={"local-issue-release-#{issue.id}"}
                        phx-submit="release_local_issue_lease"
                      >
                        <input type="hidden" name="issue_ref" value={issue.id} />
                        <button type="submit" class="secondary">Release Lease</button>
                      </form>
                    </div>
                  </div>

                  <div class="tracker-focus-grid">
                    <article class="tracker-mini-stat">
                      <span>Files</span>
                      <strong><%= local_issue_attachment_count(issue.attachments) %></strong>
                    </article>

                    <article class="tracker-mini-stat">
                      <span>Blockers</span>
                      <strong><%= local_issue_blocker_count(issue.blocked_by) %></strong>
                    </article>

                    <article class="tracker-mini-stat">
                      <span>Lease</span>
                      <strong><%= local_issue_lease_status(issue) %></strong>
                    </article>

                    <article class="tracker-mini-stat">
                      <span>Worker</span>
                      <strong><%= local_issue_worker_short_label(issue.assigned_to_worker) %></strong>
                    </article>
                  </div>

                  <div class="tracker-focus-detail-grid">
                    <article class="tracker-focus-detail-card">
                      <span>Priority</span>
                      <strong><%= local_issue_priority(issue.priority) %></strong>
                    </article>

                    <article class="tracker-focus-detail-card">
                      <span>Labels</span>
                      <strong><%= local_issue_labels(issue.labels) %></strong>
                    </article>

                    <article class="tracker-focus-detail-card">
                      <span>Workspace</span>
                      <strong class="mono"><%= runtime.workspace_path %></strong>
                    </article>

                    <article class="tracker-focus-detail-card">
                      <span>Claimed By</span>
                      <strong class="mono"><%= issue.claimed_by || "unclaimed" %></strong>
                    </article>

                    <article class="tracker-focus-detail-card">
                      <span>Updated</span>
                      <strong class="mono"><%= issue.updated_at || "n/a" %></strong>
                    </article>

                    <article class="tracker-focus-detail-card">
                      <span>Blocked By</span>
                      <strong><%= local_issue_blocked_by(issue.blocked_by) %></strong>
                    </article>
                  </div>

                  <div class="tracker-runtime-card tracker-runtime-card-compact tracker-focus-note">
                    <p class="metric-label">Mission line</p>
                    <p class="tracker-form-copy">
                      The dashboard keeps only the decision-ready snapshot here. Full files, comments, and deep runtime detail move to the dedicated issue page.
                    </p>
                  </div>

                  <div class="tracker-runtime-card tracker-runtime-card-compact">
                    <p class="metric-label">Runtime snapshot</p>
                    <dl class="tracker-detail-list tracker-runtime-list">
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
                <% else %>
                  <p class="empty-state">Select an issue to inspect its local tracker details.</p>
                <% end %>
                </article>
              </div>
            </section>

            <section class="tracker-stage tracker-stage-search">
              <div class="tracker-stage-header">
                <div>
                  <p class="eyebrow">Search and routing</p>
                  <h3 class="tracker-stage-title">Search, board view, and issue movement</h3>
                  <p class="tracker-stage-copy">
                    Search the queue, switch lanes, and move issues through the local tracker once the agent studio is in motion.
                  </p>
                </div>

                <div class="tracker-stage-meta">
                  <span class="metric-detail">
                    Showing <%= length(filtered_local_issues) %> of <%= length(@local_tracker.issues) %> issues
                  </span>
                </div>
              </div>

              <%= if @local_tracker.issues != [] do %>
                <div class="tracker-toolbar">
                  <form id="local-issue-filters" class="tracker-filter-bar" phx-change="filter_local_issues">
                    <div class="field-stack">
                      <label for="local-filter-query">Search</label>
                      <input
                        id="local-filter-query"
                        type="text"
                        name="filters[query]"
                        value={@local_issue_filters.query}
                        placeholder="Identifier, title, description"
                      />
                    </div>

                    <div class="field-stack">
                      <label for="local-filter-state">State</label>
                      <select id="local-filter-state" name="filters[state]">
                        <option value="all" selected={@local_issue_filters.state == "all"}>All states</option>
                        <option :for={state <- @local_issue_states} value={state} selected={@local_issue_filters.state == state}>
                          <%= state %>
                        </option>
                      </select>
                    </div>

                    <div class="field-stack">
                      <label for="local-filter-runtime">Runtime</label>
                      <select id="local-filter-runtime" name="filters[runtime]">
                        <option value="all" selected={@local_issue_filters.runtime == "all"}>All runtime</option>
                        <option value="running" selected={@local_issue_filters.runtime == "running"}>Running</option>
                        <option value="retrying" selected={@local_issue_filters.runtime == "retrying"}>Retrying</option>
                        <option value="idle" selected={@local_issue_filters.runtime == "idle"}>Idle</option>
                      </select>
                    </div>

                    <div class="field-stack">
                      <label for="local-filter-label">Label</label>
                      <input
                        id="local-filter-label"
                        type="text"
                        name="filters[label]"
                        value={@local_issue_filters.label}
                        placeholder="migration"
                      />
                    </div>

                    <div class="tracker-toolbar-actions">
                      <div class="field-stack tracker-view-field">
                        <label>Board view</label>
                        <div class="tracker-view-toggle">
                          <button
                            type="button"
                            class={tracker_view_button_class(@local_issue_view_mode, "list")}
                            phx-click="set_local_issue_view"
                            phx-value-mode="list"
                          >
                            List
                          </button>
                          <button
                            type="button"
                            class={tracker_view_button_class(@local_issue_view_mode, "board")}
                            phx-click="set_local_issue_view"
                            phx-value-mode="board"
                          >
                            Board
                          </button>
                        </div>
                      </div>
                    </div>
                  </form>

                  <p class="metric-detail tracker-toolbar-copy">
                    Search, board routing, and inline issue movement stay on one compact control rail whenever space allows.
                  </p>
                </div>
              <% end %>

              <%= cond do %>
                <% @local_tracker.issues == [] -> %>
                  <p class="empty-state">No local issues yet. Create one to start a new run.</p>
                <% filtered_local_issues == [] -> %>
                  <p class="empty-state">No local issues match the active filters.</p>
                <% @local_issue_view_mode == "board" -> %>
                  <div class="tracker-board">
                    <section :for={column <- board_columns} class="tracker-board-column">
                      <div class="tracker-board-column-header">
                        <span class={state_badge_class(column.state)}><%= column.state %></span>
                        <span class="muted"><%= length(column.issues) %></span>
                      </div>

                      <div class="tracker-board-stack">
                        <article
                          :for={issue <- column.issues}
                          class={local_issue_board_card_class(issue, @selected_local_issue_ref)}
                        >
                          <div class="tracker-board-card-top">
                            <div class="issue-stack">
                              <span class="issue-id"><%= issue.identifier %></span>
                              <strong class="issue-title-text"><%= issue.title %></strong>
                              <span :if={issue.description} class="muted issue-description-text"><%= issue.description %></span>
                            </div>
                            <span class={local_issue_runtime_badge_class(issue, @payload)}>
                              <%= local_issue_runtime_badge(issue, @payload) %>
                            </span>
                          </div>

                          <div class="tracker-board-meta">
                            <span>Priority <%= local_issue_priority(issue.priority) %></span>
                            <span><%= local_issue_labels(issue.labels) %></span>
                            <span><%= local_issue_attachment_count(issue.attachments) %> files</span>
                          </div>

                          <div class="tracker-board-actions">
                            <button
                              type="button"
                              class="secondary"
                              phx-click="select_local_issue"
                              phx-value-issue_ref={issue.id}
                            >
                              Focus
                            </button>

                            <a class="tracker-link-button tracker-link-button-secondary" href={local_issue_detail_href(issue)}>
                              Open
                            </a>

                            <form
                              id={"local-issue-board-state-#{issue.id}"}
                              class="issue-state-form issue-state-form-inline"
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
                          </div>
                        </article>
                      </div>
                    </section>
                  </div>
                <% true -> %>
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
                          <th>Actions</th>
                        </tr>
                      </thead>
                      <tbody>
                        <tr :for={issue <- filtered_local_issues} class={local_issue_row_class(issue, @selected_local_issue_ref)}>
                          <td>
                            <div class="issue-stack">
                              <span class="issue-id"><%= issue.identifier %></span>
                              <span class="issue-title-text"><%= issue.title %></span>
                              <span :if={issue.description} class="muted issue-description-text"><%= issue.description %></span>
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
                            <div class="tracker-list-actions">
                              <button
                                type="button"
                                class="secondary tracker-focus-button"
                                phx-click="select_local_issue"
                                phx-value-issue_ref={issue.id}
                              >
                                Focus
                              </button>

                              <a class="tracker-link-button tracker-link-button-secondary" href={local_issue_detail_href(issue)}>
                                Open
                              </a>

                              <form
                                id={"local-issue-state-#{issue.id}"}
                                class="issue-state-form issue-state-form-inline"
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
                            </div>
                          </td>
                        </tr>
                      </tbody>
                    </table>
                  </div>
              <% end %>
            </section>
          </div>
          </section>
        <% else %>
          <section class="section-card">
            <div class="section-header">
              <div>
                <h2 class="section-title">Local issues unavailable</h2>
                <p class="section-copy">
                  Switch the workflow tracker to `local` to enable issue intake, board routing, and movement on this page.
                </p>
              </div>
            </div>

            <p class="empty-state">
              Current tracker path: <span class="mono"><%= @local_tracker.path || "n/a" %></span>
            </p>
          </section>
        <% end %>
      <% end %>
    </section>
    </Layouts.dashboard_frame>
    """
  end

  defp load_payload do
    Presenter.state_payload(orchestrator(), snapshot_timeout_ms())
  end

  defp sidebar_counts(%{error: _}), do: nil
  defp sidebar_counts(payload), do: Map.get(payload, :counts)

  defp sidebar_issue_shortcut(nil), do: nil

  defp sidebar_issue_shortcut(issue) do
    %{
      label: issue.identifier,
      href: local_issue_detail_href(issue),
      meta: issue.title
    }
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp issue_upload_max_entries, do: @issue_upload_max_entries
  defp issue_upload_max_file_size, do: Local.attachment_max_file_size()

  defp format_runtime_seconds(seconds) when is_number(seconds) do
    whole_seconds = max(trunc(seconds), 0)
    mins = div(whole_seconds, 60)
    secs = rem(whole_seconds, 60)
    "#{mins}m #{secs}s"
  end

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
      lease_expires_at: local_issue_timestamp(issue.lease_expires_at),
      lease_status: issue |> Local.lease_status() |> Atom.to_string(),
      comments: local_issue_comments(Map.get(issue, :comments, []))
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
    preview_kind = Local.attachment_preview_kind(attachment)

    %{
      id: attachment["id"],
      filename: attachment["filename"] || "attachment",
      content_type: attachment["content_type"],
      byte_size: attachment["byte_size"],
      uploaded_at: attachment["uploaded_at"],
      preview_kind: preview_kind,
      previewable?: preview_kind in [:text, :image, :pdf],
      preview_path: local_issue_attachment_preview_path(issue, attachment),
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

  defp local_issue_attachment_preview_path(issue, attachment) do
    issue_ref = issue.id || issue.identifier
    attachment_id = attachment["id"]

    if is_binary(issue_ref) and is_binary(attachment_id) do
      "/api/v1/local-issues/#{URI.encode(issue_ref)}/attachments/#{URI.encode(attachment_id)}/preview"
    end
  end

  defp local_issue_attachment_count(attachments) when is_list(attachments), do: length(attachments)
  defp local_issue_attachment_count(_attachments), do: 0

  defp local_issue_blocker_count(blocked_by) when is_list(blocked_by), do: length(blocked_by)
  defp local_issue_blocker_count(_blocked_by), do: 0

  defp local_issue_lease_status(issue) do
    Map.get(issue, :lease_status) || "unclaimed"
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

  defp upload_error_message(:not_accepted),
    do: "A selected file type is not accepted. Use only the supported local tracker formats."

  defp upload_error_message(:external_client_failure),
    do: "The browser failed to finish uploading one of the selected files."

  defp upload_error_message(other), do: "Upload failed: #{inspect(other)}"

  defp local_issue_attachment_accept_summary do
    Local.attachment_allowed_extensions()
    |> Enum.join(", ")
  end

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

  defp default_local_issue_filters do
    %{query: "", state: "all", runtime: "all", label: ""}
  end

  defp normalize_local_issue_filters(filters) when is_map(filters) do
    defaults = default_local_issue_filters()

    %{
      query: Map.get(filters, "query", defaults.query) |> to_string() |> String.trim(),
      state: Map.get(filters, "state", defaults.state) |> to_string() |> String.trim() |> blank_to(defaults.state),
      runtime: Map.get(filters, "runtime", defaults.runtime) |> to_string() |> String.trim() |> blank_to(defaults.runtime),
      label: Map.get(filters, "label", defaults.label) |> to_string() |> String.trim()
    }
  end

  defp normalize_local_issue_filters(_filters), do: default_local_issue_filters()

  defp normalize_local_issue_view_mode("board"), do: "board"
  defp normalize_local_issue_view_mode(_mode), do: "list"

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

  defp local_issue_worker_short_label(false), do: "manual"
  defp local_issue_worker_short_label(_value), do: "enabled"

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

  defp filtered_local_issues(tracker, filters, payload) do
    Enum.filter(tracker.issues, fn issue ->
      local_issue_matches_query?(issue, filters.query) and
        local_issue_matches_state?(issue, filters.state) and
        local_issue_matches_runtime?(issue, filters.runtime, payload) and
        local_issue_matches_label?(issue, filters.label)
    end)
  end

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

  defp local_issue_detail_href(issue), do: "/issues/#{issue.identifier}"

  defp local_issue_row_class(issue, selected_ref) when issue.id == selected_ref,
    do: "issue-row-selected"

  defp local_issue_row_class(_issue, _selected_ref), do: nil

  defp local_issue_board_card_class(issue, selected_ref) do
    base = "tracker-board-card"

    if issue.id == selected_ref, do: "#{base} issue-row-selected", else: base
  end

  defp local_issue_release_available?(issue), do: local_issue_lease_status(issue) != "unclaimed"

  defp tracker_view_button_class(mode, mode), do: "secondary tracker-view-button tracker-view-button-active"
  defp tracker_view_button_class(_current, _mode), do: "secondary tracker-view-button"

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

  defp local_issue_board_columns(issues, states) do
    grouped =
      Enum.group_by(issues, &normalize_issue_state(&1.state))

    configured_states =
      states
      |> Enum.map(&to_string/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    discovered_states =
      issues
      |> Enum.map(& &1.state)
      |> Enum.reject(&(is_nil(&1) or to_string(&1) in configured_states))

    ordered_states =
      configured_states
      |> Kernel.++(discovered_states)
      |> Enum.uniq()

    ordered_states
    |> Enum.map(fn state ->
      %{state: state, issues: Map.get(grouped, normalize_issue_state(state), [])}
    end)
    |> Enum.reject(&(&1.issues == []))
  end

  defp tracker_feedback_class(:error), do: "tracker-feedback tracker-feedback-error"
  defp tracker_feedback_class(_kind), do: "tracker-feedback tracker-feedback-info"

  defp local_tracker_error_message(prefix, :issue_not_found), do: "#{prefix}: issue not found"

  defp local_tracker_error_message(prefix, {:unsupported_attachment_type, filename}),
    do: "#{prefix}: unsupported attachment format for #{filename}"

  defp local_tracker_error_message(prefix, {:attachment_too_large, _size, max_size}),
    do: "#{prefix}: attachment exceeds #{format_bytes(max_size)}"

  defp local_tracker_error_message(prefix, :invalid_attachment_text_encoding),
    do: "#{prefix}: text attachments must be valid UTF-8"

  defp local_tracker_error_message(prefix, reason), do: "#{prefix}: #{inspect(reason)}"

  defp normalize_issue_state(state) when is_binary(state) do
    state
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_issue_state(state), do: state |> to_string() |> normalize_issue_state()

  defp local_issue_matches_query?(_issue, ""), do: true

  defp local_issue_matches_query?(issue, query) when is_binary(query) do
    haystack =
      [issue.identifier, issue.title, issue.description, Enum.join(issue.labels || [], " ")]
      |> Enum.reject(&nil_or_empty?/1)
      |> Enum.join(" ")
      |> String.downcase()

    String.contains?(haystack, String.downcase(query))
  end

  defp local_issue_matches_state?(_issue, "all"), do: true

  defp local_issue_matches_state?(issue, state) do
    normalize_issue_state(issue.state) == normalize_issue_state(state)
  end

  defp local_issue_matches_runtime?(_issue, "all", _payload), do: true
  defp local_issue_matches_runtime?(issue, "running", payload), do: local_issue_running?(issue, payload)
  defp local_issue_matches_runtime?(issue, "retrying", payload), do: local_issue_retrying?(issue, payload)

  defp local_issue_matches_runtime?(issue, "idle", payload) do
    not local_issue_running?(issue, payload) and not local_issue_retrying?(issue, payload)
  end

  defp local_issue_matches_runtime?(_issue, _runtime, _payload), do: true

  defp local_issue_matches_label?(_issue, ""), do: true

  defp local_issue_matches_label?(issue, label) do
    normalized_label = String.downcase(label)

    Enum.any?(issue.labels || [], fn issue_label ->
      String.contains?(String.downcase(issue_label), normalized_label)
    end)
  end

  defp blank_to("", fallback), do: fallback
  defp blank_to(value, _fallback), do: value
end
