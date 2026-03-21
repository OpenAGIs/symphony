defmodule SymphonyElixirWeb.Layouts do
  @moduledoc """
  Shared layouts for the observability dashboard.
  """

  use Phoenix.Component

  @spec root(map()) :: Phoenix.LiveView.Rendered.t()
  def root(assigns) do
    assigns = assign(assigns, :csrf_token, Plug.CSRFProtection.get_csrf_token())

    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={@csrf_token} />
        <title>Symphony Observability</title>
        <script defer src="/vendor/phoenix_html/phoenix_html.js"></script>
        <script defer src="/vendor/phoenix/phoenix.js"></script>
        <script defer src="/vendor/phoenix_live_view/phoenix_live_view.js"></script>
        <script>
          window.addEventListener("DOMContentLoaded", function () {
            var csrfToken = document
              .querySelector("meta[name='csrf-token']")
              ?.getAttribute("content");

            if (!window.Phoenix || !window.LiveView) return;

            var liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket, {
              params: {_csrf_token: csrfToken}
            });

            liveSocket.connect();
            window.liveSocket = liveSocket;
          });
        </script>
        <link rel="stylesheet" href="/dashboard.css" />
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end

  @spec app(map()) :: Phoenix.LiveView.Rendered.t()
  def app(assigns) do
    ~H"""
    <main class="app-shell">
      {@inner_content}
    </main>
    """
  end

  attr(:active_section, :string, required: true)
  attr(:counts, :map, default: nil)
  attr(:issue_shortcut, :map, default: nil)
  slot(:inner_block, required: true)

  @spec dashboard_frame(map()) :: Phoenix.LiveView.Rendered.t()
  def dashboard_frame(assigns) do
    assigns = assign(assigns, :workspace_button, workspace_button(assigns[:issue_shortcut]))

    ~H"""
    <div class="observability-frame">
      <aside class="observability-sidebar">
        <a class="observability-brand" href="/">
          <span class="eyebrow">Symphony</span>
          <strong>Observability</strong>
          <span class="muted">Parallel operator surface for runtime, sessions, and issue flow.</span>

          <div class="observability-release">
            <span class="hero-chip hero-chip-neutral">Phoenix LiveView</span>
            <span class="hero-chip hero-chip-accent">dashboard release1.0</span>
          </div>

          <div class="observability-presence" aria-label="LiveView connection status">
            <span class="status-badge status-badge-live">
              <span class="status-badge-dot"></span>
              Live connected
            </span>

            <span class="status-badge status-badge-offline">
              <span class="status-badge-dot"></span>
              Connecting
            </span>
          </div>
        </a>

        <nav class="observability-nav" aria-label="Observability sections">
          <a
            class={observability_nav_class(@active_section, "overview")}
            href="/"
            aria-label="Overview"
            aria-current={observability_nav_current(@active_section, "overview")}
            title="Overview"
          >
            <strong>OVR</strong>
          </a>

          <a
            class={observability_nav_class(@active_section, "sessions")}
            href="/sessions"
            aria-label="Sessions"
            aria-current={observability_nav_current(@active_section, "sessions")}
            title="Sessions"
          >
            <strong>SES</strong>
          </a>

          <a
            class={observability_nav_class(@active_section, "issues")}
            href="/issues"
            aria-label="Issue board"
            aria-current={observability_nav_current(@active_section, "issues")}
            title="Issue board"
          >
            <strong>ISS</strong>
          </a>

          <a
            class={observability_nav_class(@active_section, "workspace")}
            href={@workspace_button.href}
            aria-label={@workspace_button.title}
            aria-current={observability_nav_current(@active_section, "workspace")}
            title={@workspace_button.title}
          >
            <strong>WRK</strong>
          </a>
        </nav>

        <div :if={@counts} class="observability-sidebar-card">
          <p class="eyebrow">Runtime snapshot</p>
          <div class="observability-sidebar-stats">
            <article>
              <span>Running</span>
              <strong><%= Map.get(@counts, :running, 0) %></strong>
            </article>
            <article>
              <span>Retrying</span>
              <strong><%= Map.get(@counts, :retrying, 0) %></strong>
            </article>
          </div>
        </div>

        <div :if={@issue_shortcut} class="observability-sidebar-card">
          <p class="eyebrow">Focused issue</p>
          <strong class="observability-sidebar-issue"><%= @issue_shortcut.label %></strong>
          <span class="muted"><%= @issue_shortcut.meta %></span>

          <%= if @active_section == "workspace" do %>
            <span class="observability-sidebar-link observability-sidebar-link-active">
              Viewing workspace
            </span>
          <% else %>
            <a class="observability-sidebar-link" href={@issue_shortcut.href}>Open workspace</a>
          <% end %>
        </div>
      </aside>

      <section class="observability-main">
        {render_slot(@inner_block)}
      </section>
    </div>
    """
  end

  defp observability_nav_class(active_section, active_section),
    do: "observability-nav-link observability-nav-link-active"

  defp observability_nav_class(_current, _target), do: "observability-nav-link"

  defp observability_nav_current(active_section, active_section), do: "page"
  defp observability_nav_current(_current, _target), do: nil

  defp workspace_button(%{href: href}) when is_binary(href) do
    %{
      href: href,
      title: "Workspace"
    }
  end

  defp workspace_button(_shortcut) do
    %{
      href: "/issues",
      title: "Workspace"
    }
  end
end
