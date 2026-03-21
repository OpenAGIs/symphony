defmodule SymphonyElixirWeb.OverviewLive do
  @moduledoc """
  Overview page for Symphony observability.
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
    <Layouts.dashboard_frame active_section="overview" counts={sidebar_counts(@payload)}>
      <section class="dashboard-shell">
        <header class="hero-card page-hero-card overview-page-hero">
          <div class="overview-header-nav-shell">
            <nav class="overview-header-nav" aria-label="Overview header navigation">
              <a class="overview-header-link overview-header-link-active" href="/" aria-current="page">
                Overview
              </a>
              <a class="overview-header-link" href="#overview-runtime">Runtime</a>
              <a class="overview-header-link" href="#overview-rhythm">System</a>
              <a class="overview-header-link" href="#overview-limits">Limits</a>
              <a class="overview-header-link" href="/sessions">Sessions</a>
              <a class="overview-header-link" href="/issues">Issues</a>
              <a class="overview-header-link" href="/api/v1/state" target="_blank" rel="noreferrer">
                API
              </a>
            </nav>
          </div>

          <div class="page-hero-grid">
            <div class="page-hero-main">
              <p class="eyebrow">Overview</p>
              <h1 class="hero-title page-hero-title">Operations Dashboard</h1>
              <p class="hero-copy page-hero-copy">
                A dedicated overview page for runtime posture, throughput, capacity, and rate-limit health before drilling into session traffic or issue routing.
              </p>

              <div :if={!@payload[:error]} class="page-hero-chip-grid">
                <article class="page-hero-chip">
                  <span>Runtime</span>
                  <strong class="numeric"><%= format_runtime_seconds(total_runtime_seconds(@payload, @now)) %></strong>
                  <p class="page-hero-chip-copy">Live plus completed Codex runtime.</p>
                </article>

                <article class="page-hero-chip">
                  <span>Next poll</span>
                  <strong><%= polling_headline(@payload.polling) %></strong>
                  <p class="page-hero-chip-copy"><%= polling_copy(@payload.polling) %></p>
                </article>

                <article class="page-hero-chip">
                  <span>Dead letters</span>
                  <strong><%= @payload.counts.dead_lettered %></strong>
                  <p class="page-hero-chip-copy">Items that exhausted retry handling.</p>
                </article>
              </div>
            </div>

            <div class="page-hero-side">
              <article class="page-hero-side-card">
                <p class="metric-label">Generated</p>
                <p class="mono page-hero-side-value"><%= @payload.generated_at || "n/a" %></p>
              </article>

              <article :if={!@payload[:error]} class="page-hero-side-card">
                <p class="metric-label">Capacity</p>
                <p class="page-hero-side-value">
                  <%= @payload.capacity.running %> / <%= @payload.capacity.limit %>
                </p>
                <p class="metric-detail"><%= @payload.capacity.available %> open slots</p>
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
          <section id="overview-runtime" class="metric-grid">
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

          <section class="overview-panel-grid">
            <article id="overview-rhythm" class="section-card">
              <div class="section-header">
                <div>
                  <h2 class="section-title">System rhythm</h2>
                  <p class="section-copy">Capacity, polling cadence, and dead-letter pressure in one board.</p>
                </div>
              </div>

              <div class="tracker-summary-grid">
                <article class="tracker-summary-card">
                  <p class="metric-label">Capacity</p>
                  <p class="metric-value"><%= @payload.capacity.running %> / <%= @payload.capacity.limit %></p>
                  <p class="metric-detail"><%= @payload.capacity.available %> open slots remain.</p>
                </article>

                <article class="tracker-summary-card">
                  <p class="metric-label">Polling</p>
                  <p class="metric-value"><%= polling_headline(@payload.polling) %></p>
                  <p class="metric-detail"><%= polling_copy(@payload.polling) %></p>
                </article>

                <article class="tracker-summary-card">
                  <p class="metric-label">Dead letters</p>
                  <p class="metric-value"><%= @payload.counts.dead_lettered %></p>
                  <p class="metric-detail">Issues that exhausted retry handling.</p>
                </article>
              </div>
            </article>

            <article id="overview-limits" class="section-card">
              <div class="section-header">
                <div>
                  <h2 class="section-title">Rate limits</h2>
                  <p class="section-copy">Latest upstream rate-limit snapshot, when available.</p>
                </div>
              </div>

              <pre class="code-panel"><%= pretty_value(@payload.rate_limits) %></pre>
            </article>
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

  defp completed_runtime_seconds(payload) do
    payload.codex_totals.seconds_running || 0
  end

  defp total_runtime_seconds(payload, now) do
    completed_runtime_seconds(payload) +
      Enum.reduce(payload.running, 0, fn entry, total ->
        total + runtime_seconds_from_started_at(entry.started_at, now)
      end)
  end

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

  defp polling_headline(%{checking?: true}), do: "Polling now"

  defp polling_headline(%{next_poll_in_ms: ms}) when is_integer(ms) do
    format_runtime_seconds(div(ms + 999, 1_000))
  end

  defp polling_headline(_polling), do: "Unavailable"

  defp polling_copy(%{poll_interval_ms: ms}) when is_integer(ms) do
    "Interval #{format_runtime_seconds(div(ms + 999, 1_000))}"
  end

  defp polling_copy(_polling), do: "Polling schedule unavailable."

  defp pretty_value(nil), do: "n/a"
  defp pretty_value(value), do: inspect(value, pretty: true, limit: :infinity)
end
