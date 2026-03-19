---
tracker:
  kind: local
  path: ./local-issues.json
  active_states:
    - Todo
    - In Progress
    - Merging
    - Rework
  terminal_states:
    - Closed
    - Cancelled
    - Canceled
    - Duplicate
    - Done
polling:
  interval_ms: 60000
workspace:
  root: ~/code/symphony-workspaces
server:
  host: 127.0.0.1
  port: 4000
hooks:
  after_create: |
    REPO_URL="${SYMPHONY_REPO_URL:-https://github.com/OpenAGIs/OpenAGI.ai.git}"
    git clone "$REPO_URL" .
    git config user.email "${SYMPHONY_GIT_EMAIL:-automation@example.invalid}"
    git config user.name "${SYMPHONY_GIT_NAME:-Symphony Automation}"
    git remote set-url origin "$REPO_URL"
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
  # Keep app-server env defaults; avoid inheriting restrictive parent shell sandbox vars.
  command: codex --config model_reasoning_effort=medium app-server
  read_timeout_ms: 60000
  approval_policy: never
  # Required for unattended git pull/commit/push inside workspace repos (.git writes + network).
  thread_sandbox: danger-full-access
  turn_sandbox_policy:
    type: dangerFullAccess
---

You are working on a local tracker issue `{{ issue.identifier }}`.

{% if attempt %}
Continuation context:

- This is retry attempt #{{ attempt }} because the issue is still in an active state.
- Resume from the current workspace state instead of starting over.
- Reuse prior notes, validation evidence, and partial implementation unless they are now incorrect.
{% endif %}

Issue context:
Identifier: {{ issue.identifier }}
Title: {{ issue.title }}
Current status: {{ issue.state }}
Labels: {{ issue.labels }}
URL: {{ issue.url }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

Instructions:

1. This is an unattended orchestration session. Never ask a human to perform follow-up actions.
2. Work only in the provided repository copy. Do not modify files outside that workspace.
3. The tracker backend is local. Keep the evolving execution plan, acceptance criteria, validation notes, and handoff summary in `.symphony/workpad.md` inside the workspace.
4. If the `symphony` CLI is available in PATH, mirror major milestones back to the local tracker with `symphony issue comment {{ issue.id }} ...` and move states with `symphony issue state {{ issue.id }} ...`. Add `--workflow <path-to-WORKFLOW.md>` when the current directory is not the Symphony control repo. If the CLI is unavailable, continue working and rely on `.symphony/workpad.md`.
5. Final message must report completed actions and blockers only. Do not include "next steps for user".

## Default posture

- Start by checking the issue's current state and route work accordingly.
- Create or update `.symphony/workpad.md` before making code changes.
- When `tracker.kind` is `linear` and the `linear_workpad` tool is available, keep the persistent `## Codex Workpad` comment aligned with the same plan, validation, and notes.
- Reproduce the current behavior first so the fix target is explicit.
- Add acceptance criteria and validation steps to the workpad before implementation.
- Keep the workpad current whenever scope, risks, or validation evidence changes.
- Keep scope tight. If you discover meaningful follow-up work, capture it in the workpad so it can become a separate local issue later.
- Prefer targeted validation that proves the changed behavior end to end.

## Related skills

- `commit`: produce clean, logical commits during implementation.
- `push`: keep remote branch current and publish updates.
- `pull`: sync with the latest default branch before handoff.
- `land`: when an issue reaches `Merging` and a PR exists, explicitly follow `.codex/skills/land/SKILL.md`.

## Status map

- `Backlog` -> out of scope for this workflow; stop and wait for the issue to move into an active state.
- `Todo` -> start planning immediately. If `symphony issue` is available, move the issue to `In Progress` before editing code.
- `In Progress` -> continue execution.
- `In Review` -> wait for feedback or a state change.
- `Merging` -> follow the `land` skill flow if a PR exists and the issue is ready to land.
- `Rework` -> re-plan, implement, and re-validate.
- `Done` -> no further action required.

## Execution flow

1. Open or create `.symphony/workpad.md` and keep these sections current:
   - Environment stamp
   - Plan
   - Acceptance Criteria
   - Validation
   - Notes
2. Capture a concrete reproduction signal and record it in `Notes`.
3. Sync with the latest default branch before code changes when the repository has a usable remote.
4. Implement against the workpad checklist. Check completed items off as you go.
5. Run the validation required for the scope. Record the commands and results in `Validation`.
6. If you produce a PR or branch intended for review, record the URL or branch name in the workpad and, when possible, mirror it back to the local issue through `symphony issue comment`.
7. Before ending the turn, make sure the workpad accurately reflects:
   - what changed,
   - what validation passed,
   - any blockers or uncertainties.
8. Only mark the issue `Done` when the requested implementation and validation are complete.

## Blocked behavior

- Only stop early for a true blocker such as missing repository access, missing required secrets, or a broken toolchain that cannot be repaired in-session.
- When blocked, write a concise blocker note in `.symphony/workpad.md`.
- If you are also using `linear_workpad`, mirror the blocker there for shared visibility.
