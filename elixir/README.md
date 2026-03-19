# Symphony Elixir

This directory contains the current Elixir/OTP implementation of Symphony, based on
[`SPEC.md`](../SPEC.md) at the repository root.

> [!WARNING]
> Symphony Elixir is prototype software intended for evaluation only and is presented as-is.
> We recommend implementing your own hardened version based on `SPEC.md`.

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

- `linear_graphql` and `linear_workpad` when the tracker is `linear`
- `local_issue_list`, `local_issue_create`, `local_issue_state`,
  `local_issue_comment`, and `local_issue_release` when the tracker is `local`

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
   - The `linear` skill is only relevant when you keep `tracker.kind: linear`.
   - Use `linear_graphql` for raw GraphQL operations such as uploads or custom mutations.
   - Use `linear_workpad` to find, create, and update the single persistent
     `## Codex Workpad` comment for an issue.
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

## Run

```bash
git clone https://github.com/openai/symphony
cd symphony/elixir
mise trust
mise install
mise exec -- mix setup
mise exec -- mix build
mise exec -- ./bin/symphony ./WORKFLOW.md
```

The bundled local workflow now also enables the browser dashboard by default at
`http://127.0.0.1:4000/`.

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

## Worker runtime outputs

Each agent run now emits a durable worker bundle under the configured log directory at
`log/worker-runs/<timestamp>-<issue>/`.

Each bundle includes:

- `metadata.json` with issue/workspace/outcome timing
- `codex-events.jsonl` with the streamed Codex turn events
- `workspace-artifacts.json` with the regular files present in the issue workspace

These files are intended to be upload-ready runtime outputs for artifact, trace, and log pipelines.

The `WORKFLOW.md` file uses YAML front matter for configuration, plus a Markdown body used as the
Codex session prompt.

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
  capabilities: [backend, frontend]
  max_risk_level: high
  max_issue_budget: 5
  max_concurrent_agents_by_capability:
    frontend: 2
  max_concurrent_agents_by_risk:
    high: 1
  max_concurrent_agents_by_budget:
    5: 1
  max_retry_attempts: 10
codex:
  command: codex app-server
workflow:
  strategy:
    mode: autonomous
  acceptance:
    - id: validation
      required: true
  retry:
    max_attempts: 3
---

You are working on a locally tracked issue {{ issue.identifier }}.

Workflow mode: {{ workflow.strategy.mode }}

Title: {{ issue.title }}
Body: {{ issue.description }}
```

Notes:

- If a value is missing, defaults are used.
- Scheduler-aware label prefixes are optional and case-insensitive after normalization:
  - `capability:<name>` or `cap:<name>` requires that capability to be present in `agent.capabilities`
  - `risk:<low|medium|high|critical>` is compared against `agent.max_risk_level`
  - `budget:<positive-integer>` is compared against `agent.max_issue_budget`
  - Quota maps under `agent.max_concurrent_agents_by_capability`, `agent.max_concurrent_agents_by_risk`, and `agent.max_concurrent_agents_by_budget` cap concurrent running issues for matching labels
- Safer Codex defaults are used when policy fields are omitted:
  - `codex.approval_policy` defaults to `{"reject":{"sandbox_approval":true,"rules":true,"mcp_elicitations":true}}`
- `codex.execution_environment` optionally selects a higher-level sandbox preset: `docker`, `vm`, `browser`, or `local_os`
  - `codex.thread_sandbox` defaults to `workspace-write`
  - `codex.turn_sandbox_policy` defaults to a `workspaceWrite` policy rooted at the current issue workspace
- Explicit `codex.thread_sandbox` and `codex.turn_sandbox_policy` values still override any preset selected through `codex.execution_environment`
- Supported `codex.approval_policy` values depend on the targeted Codex app-server version. In the current local Codex schema, string values include `untrusted`, `on-failure`, `on-request`, and `never`, and object-form `reject` is also supported.
- Supported `codex.thread_sandbox` values: `read-only`, `workspace-write`, `danger-full-access`.
- Supported `codex.turn_sandbox_policy.type` values: `dangerFullAccess`, `readOnly`,
  `externalSandbox`, `workspaceWrite`.

Preset mapping for `codex.execution_environment`:

- `docker` → `thread_sandbox: workspace-write`, `turn_sandbox_policy: workspaceWrite`
- `vm` → `thread_sandbox: workspace-write`, `turn_sandbox_policy: externalSandbox`
- `browser` → `thread_sandbox: read-only`, `turn_sandbox_policy: readOnly`
- `local_os` → `thread_sandbox: danger-full-access`, `turn_sandbox_policy: dangerFullAccess`
- `agent.max_turns` caps how many back-to-back Codex turns Symphony will run in a single agent
  invocation when a turn completes normally but the issue is still in an active state. Default: `20`.
- `agent.max_retry_attempts` caps failure/continuation retry scheduling before Symphony moves the
  issue into an on-disk dead-letter queue. Default: `10`.
- Retry and dead-letter queue state persist under `workspace.root/.symphony/orchestrator_queue.json`
  so restarts can restore pending retries without a separate database.
- If the Markdown body is blank, Symphony uses a default prompt template that includes the issue
  identifier, title, body, and tracker display name.
- Set `server.host` / `server.port` to make the browser dashboard available during local runs.
- Built-in tracker runtime support is currently provided for `linear`, `local`, and `memory`;
  `jira` and `github` resolve cleanly at the workflow/task-entry layer and can be bound to runtime
  adapters through `:tracker_adapter_modules`.
- `workflow` is an optional front-matter extension for declarative execution policy. The current
  implementation preserves and exposes `workflow.strategy`, `workflow.acceptance`,
  `workflow.approvals`, `workflow.retry`, and `workflow.writeback` as typed config and template
  data under `workflow.*`.
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
