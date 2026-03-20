# dashboard release1.0

## Summary

- Release name: `dashboard release1.0`
- Frontend implementation: `Phoenix LiveView`
- Runtime surface: `http://127.0.0.1:4000/`

## Source of truth

- LiveView: `elixir/lib/symphony_elixir_web/live/dashboard_live.ex`
- Styling: `elixir/priv/static/dashboard.css`
- Layout shell: `elixir/lib/symphony_elixir_web/components/layouts.ex`

## Included UI scope

- Hero header with runtime status
- Summary metrics for running, retrying, tokens, and runtime
- Running sessions table
- Retry queue table
- Local issue management panel

## Release marker

This release is recorded directly in the frontend code and rendered in the dashboard header as:

- `Phoenix LiveView`
- `dashboard release1.0`

## Validation

- Open `http://127.0.0.1:4000/`
- Confirm the header shows `Phoenix LiveView` and `dashboard release1.0`
- Confirm the page renders the current live issue data and local issue panel
