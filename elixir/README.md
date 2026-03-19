# Symphony Elixir

This directory contains the current Elixir/OTP implementation of Symphony, based on
[`SPEC.md`](../SPEC.md) at the repository root.

> [!WARNING]
> Symphony Elixir is prototype software intended for evaluation only and is presented as-is.
> We recommend implementing your own hardened version based on `SPEC.md`.

## Quick Start

The easiest local setup is:

1. Install dependencies.
2. Edit `WORKFLOW.md`.
3. Start Symphony.
4. Open the dashboard at `http://127.0.0.1:4000/`.

```bash
git clone https://github.com/openai/symphony
cd symphony/elixir
mise trust
mise install
mise exec -- mix setup
mise exec -- mix build
mise exec -- ./bin/symphony ./WORKFLOW.md
```

The bundled local workflow already enables the browser dashboard by default at
`http://127.0.0.1:4000/`.

## Workflow First

`WORKFLOW.md` is the main operator file. It has two parts:

- YAML front matter for runtime configuration
- Markdown body for the prompt sent to Codex on every issue turn

These are the fields most teams edit first:

- `tracker`
  Choose `linear` or `local`.
- `workspace.root`
  Where Symphony creates per-issue workspaces.
- `server.host` / `server.port`
  Enables the dashboard and JSON API.
- `hooks.after_create`
  Bootstraps a fresh issue workspace before Codex runs.
- `agent.max_concurrent_agents`
  Controls how many issues Symphony can run in parallel.
- `codex.command`
  Defines how Codex app-server is launched.

Minimal local example:

```md
---
tracker:
  kind: local
  path: ./local-issues.json
  active_states:
    - Todo
    - In Progress
  terminal_states:
    - Done
    - Closed
    - Cancelled
    - Canceled
    - Duplicate
workspace:
  root: ~/code/symphony-workspaces
server:
  host: 127.0.0.1
  port: 4000
agent:
  max_concurrent_agents: 4
  max_turns: 20
codex:
  command: codex app-server
---

You are working on a local tracker issue {{ issue.identifier }}.

Title: {{ issue.title }}
Body: {{ issue.description }}
```

Minimal Linear example:

```md
---
tracker:
  kind: linear
  project_slug: "your-project-slug"
workspace:
  root: ~/code/symphony-workspaces
agent:
  max_concurrent_agents: 10
codex:
  command: codex app-server
---

You are working on a Linear issue {{ issue.identifier }}.

Title: {{ issue.title }}
Body: {{ issue.description }}
```

## Typical Local Flow

1. Edit `WORKFLOW.md` so `tracker`, `workspace.root`, `server.port`, and
   `codex.command` match your machine and repo.
2. If you use the local tracker, create or update `local-issues.json`.
3. Start Symphony with `./bin/symphony ./WORKFLOW.md`.
4. Open `http://127.0.0.1:4000/` to watch running issues, retries, token usage,
   and local issue state.
5. Use `bin/symphony issue ...` or the dashboard to create issues, change
   states, and add comments.
6. Stop Symphony with `Ctrl-C` when you are done.

## Screenshot

![Symphony Elixir screenshot](../.github/media/elixir-screenshot.png)

## How it works

1. Polls the configured tracker for candidate work
2. Creates an isolated workspace per issue
3. Launches Codex in [App Server mode](https://developers.openai.com/codex/app-server/) inside the
   workspace
4. Sends a workflow prompt to Codex
5. Keeps Codex working on the issue until the work is done

During app-server sessions, Symphony serves tracker-aware client-side tools:

- `linear_graphql` when the tracker is `linear`
- `local_issue_list`, `local_issue_create`, `local_issue_state`, and
  `local_issue_comment` when the tracker is `local`

If a claimed issue moves to a terminal state (`Done`, `Closed`, `Cancelled`, or `Duplicate`),
Symphony stops the active agent for that issue and cleans up matching workspaces.

## How to use it

1. Make sure your codebase is set up to work well with agents: see
   [Harness engineering](https://openai.com/index/harness-engineering/).
2. Pick a tracker backend.
   - `linear`: use a Linear personal token and project slug.
   - `local`: point Symphony at a local JSON issue store and run without Linear.
3. Copy this directory's `WORKFLOW.md` to your repo.
4. Optionally copy the `commit`, `push`, `pull`, `land`, and `linear` skills to your repo.
   - The `linear` skill is only relevant when you keep `tracker.kind: linear`, because it expects
     Symphony's `linear_graphql` app-server tool for raw Linear GraphQL operations.
5. Customize the copied `WORKFLOW.md` file for your project.
   - For `linear`, get your project's slug by right-clicking the project and copying its URL. The
     slug is part of the URL.
   - For `local`, set `tracker.path` to a writable JSON file.
   - When using `linear`, note that the stock workflow depends on non-standard Linear issue
     statuses: "Rework", "Human Review", and "Merging". You can customize them in
     Team Settings → Workflow in Linear.
6. Follow the instructions below to install the required runtime dependencies and start the service.

## Prerequisites

We recommend using [mise](https://mise.jdx.dev/) to manage Elixir/Erlang versions.

```bash
mise install
mise exec -- elixir --version
```

## Configuration

Pass a custom workflow file path to `./bin/symphony` when starting the service:

```bash
./bin/symphony /path/to/custom/WORKFLOW.md
```

If no path is passed, Symphony defaults to `./WORKFLOW.md`.

Optional flags:

- `--logs-root` tells Symphony to write logs under a different directory (default: `./log`)
- `--port` overrides the dashboard port defined in `WORKFLOW.md`

You can print the configured dashboard URL at any time with:

```bash
./bin/symphony panel
```

The `WORKFLOW.md` file uses YAML front matter for configuration, plus a Markdown
body used as the Codex session prompt.

Minimal example:

```md
---
tracker:
  kind: linear
  project_slug: "..."
workspace:
  root: ~/code/workspaces
hooks:
  after_create: |
    python3 "$SYMPHONY_WORKFLOW_DIR/scripts/ops/symphony_workspace_bootstrap.py" bootstrap \
      --workspace "$SYMPHONY_WORKSPACE" \
      --issue "$SYMPHONY_ISSUE_IDENTIFIER" \
      --repo-url "$SYMPHONY_BOOTSTRAP_REPO_URL" \
      --default-branch "${SYMPHONY_BOOTSTRAP_DEFAULT_BRANCH:-main}" \
      --cache-base "${SYMPHONY_BOOTSTRAP_CACHE_BASE:-$HOME/.cache/symphony/repos}" \
      --cache-key "${SYMPHONY_BOOTSTRAP_CACHE_KEY:-}" \
      --json
agent:
  max_concurrent_agents: 10
  max_turns: 20
codex:
  command: codex app-server
---

You are working on a Linear issue {{ issue.identifier }}.

Title: {{ issue.title }} Body: {{ issue.description }}
```

Local-only example:

```md
---
tracker:
  kind: local
  path: ./local-issues.json
  active_states: ["Todo", "In Progress"]
  terminal_states: ["Done", "Closed", "Cancelled", "Canceled", "Duplicate"]
workspace:
  root: ~/code/workspaces
server:
  host: 127.0.0.1
  port: 4000
agent:
  max_concurrent_agents: 4
codex:
  command: codex app-server
---

You are working on a locally tracked issue {{ issue.identifier }}.

Title: {{ issue.title }}
Body: {{ issue.description }}
```

Notes:

- If a value is missing, defaults are used.
- Safer Codex defaults are used when policy fields are omitted:
  - `codex.approval_policy` defaults to `{"reject":{"sandbox_approval":true,"rules":true,"mcp_elicitations":true}}`
  - `codex.thread_sandbox` defaults to `workspace-write`
  - `codex.turn_sandbox_policy` defaults to a `workspaceWrite` policy rooted at the current issue workspace
- Supported `codex.approval_policy` values depend on the targeted Codex app-server version. In the current local Codex schema, string values include `untrusted`, `on-failure`, `on-request`, and `never`, and object-form `reject` is also supported.
- Supported `codex.thread_sandbox` values: `read-only`, `workspace-write`, `danger-full-access`.
- Supported `codex.turn_sandbox_policy.type` values: `dangerFullAccess`, `readOnly`,
  `externalSandbox`, `workspaceWrite`.
- `agent.max_turns` caps how many back-to-back Codex turns Symphony will run in a single agent
  invocation when a turn completes normally but the issue is still in an active state. Default: `20`.
- If the Markdown body is blank, Symphony uses a default prompt template that includes the issue
  identifier, title, and body.
- Set `server.host` / `server.port` to make the browser dashboard available during local runs.
- Use `hooks.after_create` to bootstrap a fresh workspace. For a Git-backed repo, you can run
  `git clone ... .` there, along with any other setup commands you need.
- Hook commands receive `SYMPHONY_WORKSPACE`, `SYMPHONY_ISSUE_ID`, `SYMPHONY_ISSUE_IDENTIFIER`,
  `SYMPHONY_WORKFLOW_FILE`, and `SYMPHONY_WORKFLOW_DIR`, which makes it safe to call bootstrap
  helpers that live next to the source `WORKFLOW.md` even before the workspace repo exists.
- Those hook env vars are enough to support a shared local mirror + `git worktree` bootstrap,
  so parallel Symphony workspaces can reuse one cached repo instead of re-cloning on each issue.
- If a hook needs `mise exec` inside a freshly cloned workspace, trust the repo config and fetch
  the project dependencies in `hooks.after_create` before invoking `mise` later from other hooks.
- `tracker.api_key` reads from `LINEAR_API_KEY` when unset or when value is `$LINEAR_API_KEY`.
- For path values, `~` is expanded to the home directory.
- For env-backed path values, use `$VAR`. `workspace.root` resolves `$VAR` before path handling,
  while `codex.command` stays a shell command string and any `$VAR` expansion there happens in the
  launched shell.

```yaml
tracker:
  api_key: $LINEAR_API_KEY
workspace:
  root: $SYMPHONY_WORKSPACE_ROOT
hooks:
  after_create: |
    python3 "$SYMPHONY_WORKFLOW_DIR/scripts/ops/symphony_workspace_bootstrap.py" bootstrap \
      --workspace "$SYMPHONY_WORKSPACE" \
      --issue "$SYMPHONY_ISSUE_IDENTIFIER" \
      --repo-url "$SYMPHONY_BOOTSTRAP_REPO_URL" \
      --default-branch "${SYMPHONY_BOOTSTRAP_DEFAULT_BRANCH:-main}" \
      --cache-base "${SYMPHONY_BOOTSTRAP_CACHE_BASE:-$HOME/.cache/symphony/repos}" \
      --cache-key "${SYMPHONY_BOOTSTRAP_CACHE_KEY:-}" \
      --json
codex:
  command: "$CODEX_BIN app-server --model gpt-5.3-codex"
```

- If `WORKFLOW.md` is missing or has invalid YAML, startup and scheduling are halted until fixed.
- `server.port` or CLI `--port` enables the optional Phoenix LiveView dashboard and JSON API at
  `/`, `/api/v1/state`, `/api/v1/<issue_identifier>`, and `/api/v1/refresh`.

## Running without Linear

Set `tracker.kind: local` and point `tracker.path` at a JSON issue store. Symphony will then reuse
the same multi-issue orchestrator, workspace isolation, and `agent.max_concurrent_agents` fan-out
without calling Linear at all.

Sample local issue store:

```json
{
  "issues": [
    {
      "id": "local-1",
      "identifier": "LOCAL-1",
      "title": "Refactor the scheduler retry path",
      "description": "Move retry state into the orchestrator and add regression coverage.",
      "priority": 1,
      "state": "Todo",
      "labels": ["orchestrator", "scheduler"],
      "assigned_to_worker": true
    },
    {
      "id": "local-2",
      "identifier": "LOCAL-2",
      "title": "Replace tracker-specific prompt copy",
      "description": "Rename Linear-specific wording in runtime prompts and docs.",
      "priority": 2,
      "state": "In Progress",
      "labels": ["docs"],
      "assigned_to_worker": true
    }
  ]
}
```

If you want a starter file, copy [`examples/local-issues.sample.json`](./examples/local-issues.sample.json).

For day-to-day local operation, the bundled [`WORKFLOW.md`](./WORKFLOW.md) now points at
[`local-issues.json`](./local-issues.json). You can manage that store from the CLI:

```bash
bin/symphony issue list
bin/symphony issue create --title "Replace the remaining Linear handoffs"
bin/symphony issue state LOCAL-1 "In Progress"
bin/symphony issue comment LOCAL-1 "Validation passed locally."
```

When the web dashboard is enabled, the `/` LiveView also exposes a local issue panel for creating
issues and moving them between states without leaving the browser.

Local runs also expose repo-native dynamic tools inside Codex app-server turns, so skills can list,
create, comment on, and move local issues without going through Linear.

## Web dashboard

The observability UI now runs on a minimal Phoenix stack:

- LiveView for the dashboard at `/`
- JSON API for operational debugging under `/api/v1/*`
- Bandit as the HTTP server
- Phoenix dependency static assets for the LiveView client bootstrap

## Project Layout

- `lib/`: application code and Mix tasks
- `test/`: ExUnit coverage for runtime behavior
- `WORKFLOW.md`: in-repo workflow contract used by local runs
- `../.codex/`: repository-local Codex skills and setup helpers

## Testing

```bash
make all
```

## FAQ

### Why Elixir?

Elixir is built on Erlang/BEAM/OTP, which is great for supervising long-running processes. It has an
active ecosystem of tools and libraries. It also supports hot code reloading without stopping
actively running subagents, which is very useful during development.

### What's the easiest way to set this up for my own codebase?

Launch `codex` in your repo, give it the URL to the Symphony repo, and ask it to set things up for
you.

## License

This project is licensed under the [Apache License 2.0](../LICENSE).
