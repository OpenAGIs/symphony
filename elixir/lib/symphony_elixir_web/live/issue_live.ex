defmodule SymphonyElixirWeb.IssueLive do
  @moduledoc """
  Dedicated issue workspace for Symphony's observability dashboard.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.{Config, Tracker.Local}
  alias SymphonyElixirWeb.{Endpoint, Layouts, ObservabilityPubSub, Presenter}

  @runtime_tick_ms 1_000

  @impl true
  def mount(%{"issue_identifier" => issue_identifier}, _session, socket) do
    socket =
      socket
      |> assign(:issue_identifier, issue_identifier)
      |> assign(:issue_feedback, nil)
      |> assign(:issue_payload, nil)
      |> assign(:issue_error, nil)
      |> assign(:local_issue_states, local_issue_states())
      |> assign(:selected_attachment_id, nil)
      |> assign(:now, DateTime.utc_now())
      |> load_issue()

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
     |> assign(:now, DateTime.utc_now())
     |> load_issue()}
  end

  @impl true
  def handle_event("select_local_attachment", %{"attachment_id" => attachment_id}, socket) do
    {:noreply, assign(socket, :selected_attachment_id, attachment_id)}
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
         |> assign(:issue_feedback, %{kind: :info, message: "Updated #{issue_ref} to #{state}"})
         |> load_issue()}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:issue_feedback, %{
           kind: :error,
           message: local_tracker_error_message("Failed to update local issue state", reason)
         })
         |> load_issue()}
    end
  end

  def handle_event("release_local_issue_lease", %{"issue_ref" => issue_ref}, socket) do
    case Local.release_issue_claim(issue_ref) do
      :ok ->
        ObservabilityPubSub.broadcast_update()

        {:noreply,
         socket
         |> assign(:issue_feedback, %{kind: :info, message: "Released lease on #{issue_ref}"})
         |> load_issue()}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:issue_feedback, %{
           kind: :error,
           message: local_tracker_error_message("Failed to release local issue lease", reason)
         })
         |> load_issue()}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.dashboard_frame
      active_section="workspace"
      issue_shortcut={%{
        label: @issue_identifier,
        href: "/issues/#{@issue_identifier}",
        meta: "Current issue workspace"
      }}
    >
    <section class="dashboard-shell issue-page-shell">

      <%= if @issue_error do %>
        <section class="error-card">
          <h1 class="error-title">Issue unavailable</h1>
          <p class="error-copy">
            <strong><%= @issue_error.code %>:</strong> <%= @issue_error.message %>
          </p>
        </section>
      <% else %>
        <% payload = @issue_payload %>
        <% tracked = tracked_issue(payload) %>
        <% attachments = tracked_attachments(payload) %>
        <% comments = tracked_comments(payload) %>
        <% selected_attachment = selected_attachment(attachments, @selected_attachment_id) %>

        <header class="hero-card issue-hero-card">
          <div class="issue-hero-grid">
            <div class="issue-title-stack">
              <p class="eyebrow">Issue Workspace</p>
              <div class="issue-hero-reference-row">
                <span class="issue-hero-id-badge"><%= @issue_identifier %></span>
              </div>
              <h1 class="hero-title issue-hero-title">
                <%= tracked[:title] || "Issue workspace" %>
              </h1>
              <p class="hero-copy issue-hero-copy"><%= issue_intro_copy(payload) %></p>

              <div class="tracker-pill-row issue-hero-pills">
                <span class={state_badge_class(issue_state(payload))}><%= issue_state(payload) %></span>
                <span class={issue_runtime_badge_class(payload)}><%= issue_runtime_badge(payload) %></span>

                <span :if={local_issue?(payload)} class="state-badge">
                  Local tracker
                </span>
              </div>

              <div class="hero-toolbar issue-hero-actions">
                <nav class="hero-section-nav" aria-label="Issue workspace quick actions">
                  <a class="hero-action-button" href="/issues">
                    <strong>Back to issues</strong>
                    <span>Return to intake and routing</span>
                  </a>

                  <a class="hero-action-button" href="/">
                    <strong>Overview</strong>
                    <span>Global runtime posture</span>
                  </a>

                  <a class="hero-action-button" href="/sessions">
                    <strong>Sessions</strong>
                    <span>Live execution lanes</span>
                  </a>
                </nav>

                <div class="hero-utility-row">
                  <a
                    class="hero-utility-button"
                    href={"/api/v1/#{@issue_identifier}"}
                    target="_blank"
                    rel="noreferrer"
                  >
                    <strong>JSON API</strong>
                    <span>Open the issue payload</span>
                  </a>
                </div>

                <p class="hero-toolbar-copy">
                  This workspace is for deep issue context and movement. Use the board when you need to compare or reroute multiple issues together.
                </p>
              </div>

              <div class="page-hero-chip-grid issue-hero-chip-grid">
                <article class="page-hero-chip">
                  <span>Files</span>
                  <strong><%= length(attachments) %></strong>
                  <p class="page-hero-chip-copy">Local attachments and previews for this workspace.</p>
                </article>

                <article class="page-hero-chip">
                  <span>Comments</span>
                  <strong><%= length(comments) %></strong>
                  <p class="page-hero-chip-copy">Timeline notes that stay aligned with the issue.</p>
                </article>

                <article class="page-hero-chip">
                  <span>Lease</span>
                  <strong><%= tracked[:lease_status] || "n/a" %></strong>
                  <p class="page-hero-chip-copy">Current claim posture for local tracker movement.</p>
                </article>
              </div>
            </div>

            <div class="issue-hero-meta">
              <article class="issue-hero-stat">
                <p class="metric-label">Workspace</p>
                <p class="mono issue-hero-stat-value"><%= payload.workspace.path %></p>
              </article>

              <article class="issue-hero-stat">
                <p class="metric-label">Session</p>
                <p class="mono issue-hero-stat-value"><%= running_session_id(payload) || "n/a" %></p>
              </article>

              <article class="issue-hero-stat">
                <p class="metric-label">Runtime</p>
                <p class="issue-hero-stat-value">
                  <%= running_runtime(payload, @now) || retry_due_at(payload) || "n/a" %>
                </p>
              </article>
            </div>
          </div>
        </header>

        <%= if @issue_feedback do %>
          <p class={tracker_feedback_class(@issue_feedback.kind)}>
            <%= @issue_feedback.message %>
          </p>
        <% end %>

        <section class="issue-board-grid">
          <article class="tracker-detail-card issue-column-card">
            <div class="tracker-detail-intro">
              <p class="eyebrow">Mission Board</p>
              <div class="tracker-detail-header">
                <div class="issue-stack">
                  <strong><%= tracked[:title] || "Runtime detail" %></strong>
                  <span class="muted">
                    Operator-ready issue context, workspace pointers, and metadata aligned in one lane.
                  </span>
                </div>

                <a :if={tracked[:url]} class="issue-link" href={tracked.url} target="_blank" rel="noreferrer">
                  Open linked source
                </a>
              </div>
            </div>

            <div class="tracker-detail-highlights">
              <article class="tracker-mini-stat">
                <span>Files</span>
                <strong><%= length(attachments) %></strong>
              </article>

              <article class="tracker-mini-stat">
                <span>Comments</span>
                <strong><%= length(comments) %></strong>
              </article>

              <article class="tracker-mini-stat">
                <span>Priority</span>
                <strong><%= local_issue_priority(tracked[:priority]) %></strong>
              </article>

              <article class="tracker-mini-stat">
                <span>Lease</span>
                <strong><%= tracked[:lease_status] || "n/a" %></strong>
              </article>
            </div>

            <dl class="tracker-detail-list">
              <div>
                <dt>Identifier</dt>
                <dd><%= @issue_identifier %></dd>
              </div>
              <div>
                <dt>Labels</dt>
                <dd><%= local_issue_labels(tracked[:labels] || []) %></dd>
              </div>
              <div>
                <dt>Blocked By</dt>
                <dd><%= local_issue_blocked_by(tracked[:blocked_by] || []) %></dd>
              </div>
              <div>
                <dt>Branch</dt>
                <dd class="mono"><%= tracked[:branch_name] || "n/a" %></dd>
              </div>
              <div>
                <dt>Created</dt>
                <dd class="mono"><%= tracked[:created_at] || "n/a" %></dd>
              </div>
              <div>
                <dt>Updated</dt>
                <dd class="mono"><%= tracked[:updated_at] || "n/a" %></dd>
              </div>
              <div>
                <dt>Claimed By</dt>
                <dd class="mono"><%= tracked[:claimed_by] || "unclaimed" %></dd>
              </div>
              <div>
                <dt>Lease Expires</dt>
                <dd class="mono"><%= tracked[:lease_expires_at] || "n/a" %></dd>
              </div>
            </dl>

            <div :if={present?(tracked[:description])} class="code-panel issue-inline-panel">
              <p class="metric-label">Scope</p>
              <pre><%= tracked.description %></pre>
            </div>
          </article>

          <article class="tracker-detail-card issue-column-card">
            <div class="tracker-detail-intro">
              <p class="eyebrow">Runtime Lane</p>
              <div class="tracker-detail-header">
                <div class="issue-stack">
                  <strong>Live execution and retry posture</strong>
                  <span class="muted">
                    Session status, retries, tokens, and latest agent notes stay grouped for fast diagnosis.
                  </span>
                </div>
              </div>
            </div>

            <div class="tracker-summary-grid issue-summary-grid">
              <article class="tracker-summary-card">
                <p class="metric-label">Turns</p>
                <p class="metric-value"><%= running_turn_count(payload) %></p>
                <p class="metric-detail">Current session turn count.</p>
              </article>

              <article class="tracker-summary-card">
                <p class="metric-label">Tokens</p>
                <p class="metric-value"><%= running_total_tokens(payload) %></p>
                <p class="metric-detail">Total tokens for the active run.</p>
              </article>

              <article class="tracker-summary-card">
                <p class="metric-label">Retry attempt</p>
                <p class="metric-value"><%= retry_attempt(payload) %></p>
                <p class="metric-detail">Current retry slot, if backoff is active.</p>
              </article>

              <article class="tracker-summary-card">
                <p class="metric-label">Restart count</p>
                <p class="metric-value"><%= restart_count(payload) %></p>
                <p class="metric-detail">Completed retries before the current attempt.</p>
              </article>
            </div>

            <dl class="tracker-detail-list tracker-runtime-list">
              <div>
                <dt>Started</dt>
                <dd class="mono"><%= running_started_at(payload) || "n/a" %></dd>
              </div>
              <div>
                <dt>Last Event</dt>
                <dd><%= running_last_event(payload) || "n/a" %></dd>
              </div>
              <div>
                <dt>Last Update</dt>
                <dd class="mono"><%= running_last_event_at(payload) || "n/a" %></dd>
              </div>
              <div>
                <dt>Retry Due</dt>
                <dd class="mono"><%= retry_due_at(payload) || "n/a" %></dd>
              </div>
            </dl>

            <div :if={present?(running_last_message(payload))} class="tracker-runtime-note">
              <p class="metric-label">Latest Agent Note</p>
              <pre><%= running_last_message(payload) %></pre>
            </div>

            <div :if={present?(retry_error(payload))} class="tracker-runtime-note tracker-runtime-note-error">
              <p class="metric-label">Last Error</p>
              <pre><%= retry_error(payload) %></pre>
            </div>
          </article>

          <article class="tracker-detail-card issue-column-card">
            <div class="tracker-detail-intro">
              <p class="eyebrow">Movement</p>
              <div class="tracker-detail-header">
                <div class="issue-stack">
                  <strong>State movement and operator actions</strong>
                  <span class="muted">
                    Keep the local issue moving from the dedicated workspace instead of overloading the dashboard.
                  </span>
                </div>
              </div>
            </div>

            <%= if local_issue?(payload) do %>
              <form
                id="issue-page-state-form"
                class="issue-state-form"
                phx-submit="update_local_issue_state"
              >
                <input type="hidden" name="issue_ref" value={local_issue_ref(payload)} />

                <div class="field-stack">
                  <label for="issue-page-state">State</label>
                  <select id="issue-page-state" name="state">
                    <option
                      :for={state <- @local_issue_states}
                      selected={state == tracked[:state]}
                      value={state}
                    >
                      <%= state %>
                    </option>
                  </select>
                </div>

                <button type="submit">Move issue</button>
              </form>

              <form
                :if={local_issue_release_available?(payload)}
                id="issue-page-release-form"
                phx-submit="release_local_issue_lease"
              >
                <input type="hidden" name="issue_ref" value={local_issue_ref(payload)} />
                <button type="submit" class="secondary issue-release-button">Release Lease</button>
              </form>
            <% else %>
              <p class="empty-state issue-readonly-copy">
                This issue is currently observable here, but it is not backed by the local tracker for inline mutation.
              </p>
            <% end %>

            <div class="tracker-runtime-card issue-inline-panel">
              <p class="metric-label">Workspace path</p>
              <pre class="mono"><%= payload.workspace.path %></pre>
            </div>

            <div class="tracker-runtime-card issue-inline-panel">
              <p class="metric-label">Activity summary</p>
              <p class="tracker-form-copy"><%= activity_summary(payload) %></p>
            </div>
          </article>
        </section>

        <section class="issue-secondary-grid">
          <article class="section-card">
            <div class="section-header">
              <div>
                <h2 class="section-title">Files</h2>
                <p class="section-copy">Attachment previews and downloads stay visible beside the issue workspace.</p>
              </div>
              <span class="metric-detail"><%= attachment_summary(attachments) %></span>
            </div>

            <%= if attachments == [] do %>
              <p class="empty-state">No files uploaded for this issue yet.</p>
            <% else %>
              <div class="tracker-attachment-list">
                <article
                  :for={attachment <- attachments}
                  class={attachment_row_class(attachment, @selected_attachment_id)}
                >
                  <div class="tracker-attachment-copy">
                    <strong><%= attachment.filename %></strong>
                    <span class="muted"><%= attachment_meta(attachment) %></span>
                    <span class="tracker-attachment-kind">
                      <%= attachment_preview_label(attachment.preview_kind) %>
                    </span>
                  </div>

                  <div class="tracker-attachment-actions">
                    <button
                      :if={attachment_previewable?(attachment)}
                      type="button"
                      class="secondary"
                      phx-click="select_local_attachment"
                      phx-value-attachment_id={attachment.id}
                    >
                      Preview
                    </button>
                    <a class="secondary tracker-attachment-link issue-action-link" href={attachment.download_url}>
                      Download
                    </a>
                  </div>
                </article>
              </div>

              <%= if selected_attachment && attachment_previewable?(selected_attachment) do %>
                <div class="attachment-preview-panel">
                  <div class="attachment-preview-header">
                    <div>
                      <p class="metric-label">Attachment Preview</p>
                      <p class="attachment-preview-copy">
                        <%= selected_attachment.filename %> · <%= attachment_preview_label(selected_attachment.preview_kind) %>
                      </p>
                    </div>
                  </div>

                  <%= if selected_attachment.preview_kind == "image" do %>
                    <img
                      class="attachment-preview-image"
                      src={selected_attachment.preview_url}
                      alt={selected_attachment.filename}
                    />
                  <% else %>
                    <iframe
                      class={attachment_preview_frame_class(selected_attachment.preview_kind)}
                      src={selected_attachment.preview_url}
                      title={selected_attachment.filename}
                    ></iframe>
                  <% end %>
                </div>
              <% else %>
                <p class="empty-state attachment-preview-empty">
                  Preview is available for text, image, and PDF files.
                </p>
              <% end %>
            <% end %>
          </article>

          <article class="section-card">
            <div class="section-header">
              <div>
                <h2 class="section-title">Comments</h2>
                <p class="section-copy">Local timeline notes remain aligned with the issue workspace.</p>
              </div>
              <span class="metric-detail"><%= length(comments) %> notes</span>
            </div>

            <%= if comments == [] do %>
              <p class="empty-state">No local comments yet.</p>
            <% else %>
              <div class="issue-comment-stack">
                <article :for={comment <- comments} class="tracker-runtime-note issue-comment-card">
                  <p class="metric-label"><%= comment.created_at || "timestamp unavailable" %></p>
                  <pre><%= comment.body %></pre>
                </article>
              </div>
            <% end %>
          </article>
        </section>
      <% end %>
    </section>
    </Layouts.dashboard_frame>
    """
  end

  defp load_issue(socket) do
    case Presenter.issue_payload(socket.assigns.issue_identifier, orchestrator(), snapshot_timeout_ms()) do
      {:ok, payload} ->
        attachments = tracked_attachments(payload)

        socket
        |> assign(:issue_payload, payload)
        |> assign(:issue_error, nil)
        |> assign(
          :selected_attachment_id,
          resolve_selected_attachment_id(attachments, socket.assigns[:selected_attachment_id])
        )

      {:error, :issue_not_found} ->
        socket
        |> assign(:issue_payload, nil)
        |> assign(:selected_attachment_id, nil)
        |> assign(:issue_error, %{code: "issue_not_found", message: "Issue not found in the current runtime or local tracker."})
    end
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

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

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end

  defp tracked_issue(payload) do
    Map.get(payload, :tracked) || %{}
  end

  defp local_issue?(payload) do
    tracked = tracked_issue(payload)
    present?(tracked[:id] || tracked[:identifier])
  end

  defp local_issue_ref(payload) do
    tracked = tracked_issue(payload)
    tracked[:id] || tracked[:identifier]
  end

  defp issue_state(payload) do
    tracked = tracked_issue(payload)
    tracked[:state] || payload[:status] || "Unknown"
  end

  defp issue_runtime_badge(payload) do
    tracked = tracked_issue(payload)

    cond do
      payload[:retry] -> "Retrying"
      payload[:running] -> "Running"
      tracked[:lease_status] == "active" -> "Leased"
      tracked[:lease_status] == "expired" -> "Lease Expired"
      true -> "Idle"
    end
  end

  defp issue_runtime_badge_class(payload) do
    base = "state-badge"
    tracked = tracked_issue(payload)

    cond do
      payload[:retry] -> "#{base} state-badge-danger"
      payload[:running] -> "#{base} state-badge-active"
      tracked[:lease_status] == "active" -> "#{base} state-badge-warning"
      tracked[:lease_status] == "expired" -> "#{base} state-badge-danger"
      true -> base
    end
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

  defp issue_intro_copy(payload) do
    tracked = tracked_issue(payload)

    cond do
      present?(tracked[:description]) ->
        tracked.description

      present?(running_last_message(payload)) ->
        running_last_message(payload)

      present?(retry_error(payload)) ->
        retry_error(payload)

      true ->
        "A dedicated issue workspace for scanning context, runtime health, attachments, comments, and movement controls in one place."
    end
  end

  defp running_session_id(payload), do: get_in(payload, [:running, :session_id])
  defp running_turn_count(payload), do: get_in(payload, [:running, :turn_count]) || 0
  defp running_started_at(payload), do: get_in(payload, [:running, :started_at])
  defp running_last_event(payload), do: get_in(payload, [:running, :last_event])
  defp running_last_event_at(payload), do: get_in(payload, [:running, :last_event_at])
  defp running_last_message(payload), do: get_in(payload, [:running, :last_message])
  defp retry_due_at(payload), do: get_in(payload, [:retry, :due_at])
  defp retry_error(payload), do: get_in(payload, [:retry, :error])
  defp retry_attempt(payload), do: get_in(payload, [:attempts, :current_retry_attempt]) || 0
  defp restart_count(payload), do: get_in(payload, [:attempts, :restart_count]) || 0

  defp running_total_tokens(payload) do
    payload
    |> get_in([:running, :tokens, :total_tokens])
    |> format_int()
  end

  defp running_runtime(payload, now) do
    case running_started_at(payload) do
      nil -> nil
      started_at -> format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))
    end
  end

  defp activity_summary(payload) do
    cond do
      payload[:running] ->
        "Session #{running_session_id(payload) || "n/a"} is live with #{running_turn_count(payload)} turns and #{running_total_tokens(payload)} total tokens."

      payload[:retry] ->
        "Retry attempt #{retry_attempt(payload)} is queued for #{retry_due_at(payload) || "an unknown time"}."

      local_issue?(payload) ->
        "The issue is currently idle in the local tracker and ready for the next routing decision."

      true ->
        "This workspace is currently read-only and only exposes the latest observability snapshot."
    end
  end

  defp tracked_attachments(payload) do
    payload
    |> tracked_issue()
    |> Map.get(:attachments, [])
  end

  defp tracked_comments(payload) do
    payload
    |> tracked_issue()
    |> Map.get(:comments, [])
  end

  defp resolve_selected_attachment_id([], _current_id), do: nil

  defp resolve_selected_attachment_id(attachments, current_id) do
    cond do
      is_binary(current_id) and Enum.any?(attachments, &(&1.id == current_id)) ->
        current_id

      attachment = Enum.find(attachments, &attachment_previewable?/1) ->
        attachment.id

      attachment = List.first(attachments) ->
        attachment.id

      true ->
        nil
    end
  end

  defp selected_attachment(attachments, attachment_id) when is_binary(attachment_id) do
    Enum.find(attachments, &(&1.id == attachment_id))
  end

  defp selected_attachment(attachments, _attachment_id) do
    Enum.find(attachments, &attachment_previewable?/1) || List.first(attachments)
  end

  defp attachment_previewable?(attachment) do
    attachment.preview_kind in ["text", "image", "pdf"]
  end

  defp attachment_preview_label("text"), do: "inline text preview"
  defp attachment_preview_label("image"), do: "image preview"
  defp attachment_preview_label("pdf"), do: "pdf preview"
  defp attachment_preview_label(_kind), do: "download only"

  defp attachment_summary([]), do: "0 files"

  defp attachment_summary(attachments) do
    count = length(attachments)
    total_bytes = Enum.reduce(attachments, 0, &(Map.get(&1, :byte_size, 0) + &2))
    "#{count} file#{if count == 1, do: "", else: "s"} · #{format_bytes(total_bytes)}"
  end

  defp attachment_meta(attachment) do
    [attachment.content_type, format_bytes(attachment.byte_size), attachment.uploaded_at]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" · ")
  end

  defp attachment_row_class(attachment, selected_attachment_id) do
    base = "tracker-attachment-item"

    if attachment.id == selected_attachment_id, do: "#{base} tracker-attachment-item-selected", else: base
  end

  defp attachment_preview_frame_class("text"), do: "attachment-preview-frame attachment-preview-frame-text"
  defp attachment_preview_frame_class(_kind), do: "attachment-preview-frame"

  defp local_issue_release_available?(payload) do
    tracked = tracked_issue(payload)
    local_issue?(payload) and tracked[:lease_status] != "unclaimed"
  end

  defp local_issue_priority(nil), do: "n/a"
  defp local_issue_priority(priority), do: Integer.to_string(priority)

  defp local_issue_labels([]), do: "n/a"
  defp local_issue_labels(labels), do: Enum.join(labels, ", ")

  defp local_issue_blocked_by([]), do: "none"
  defp local_issue_blocked_by(values), do: Enum.join(values, ", ")

  defp tracker_feedback_class(:error), do: "tracker-feedback tracker-feedback-error"
  defp tracker_feedback_class(_kind), do: "tracker-feedback tracker-feedback-info"

  defp local_tracker_error_message(prefix, :issue_not_found), do: "#{prefix}: issue not found"

  defp local_tracker_error_message(prefix, reason), do: "#{prefix}: #{inspect(reason)}"

  defp format_int(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  defp format_int(_value), do: "0"

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

  defp format_bytes(value) when is_integer(value) and value >= 1_000_000_000,
    do: :io_lib.format("~.1f GB", [value / 1_000_000_000]) |> IO.iodata_to_binary()

  defp format_bytes(value) when is_integer(value) and value >= 1_000_000,
    do: :io_lib.format("~.1f MB", [value / 1_000_000]) |> IO.iodata_to_binary()

  defp format_bytes(value) when is_integer(value) and value >= 1_000,
    do: :io_lib.format("~.1f KB", [value / 1_000]) |> IO.iodata_to_binary()

  defp format_bytes(value) when is_integer(value) and value >= 0, do: "#{value} B"
  defp format_bytes(_value), do: "n/a"

  defp present?(value), do: not blank?(value)
  defp blank?(value), do: value in [nil, ""]
end
