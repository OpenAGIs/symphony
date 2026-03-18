## Codex Workpad

```text
jxrt:/Users/jxrt/Desktop/symphony-main/.work/publish-symphony-20260318@fc60c9e
```

### Plan

- [x] Add tracker-backed lease fields and atomic claim/release helpers for the local tracker store.
- [x] Teach the orchestrator to claim before dispatch, renew leases while running, and release on exit/retry/terminal cleanup.
- [x] Surface lease ownership in the local dashboard and issue payloads so operators can see which runtime owns work.
- [x] Validate distributed-local behavior with tracker/orchestrator/dashboard coverage.

### Acceptance Criteria

- [x] A local issue can be atomically claimed from the JSON tracker by one runtime and rejected for another while the lease is active.
- [x] Running work renews its lease and releases it on completion, retry, or terminal-state cleanup.
- [x] Dashboard/API output exposes enough lease metadata to diagnose which runtime currently owns an issue.
- [x] `make -C elixir all` passes after the lease changes.

### Validation

- [x] `mix test test/symphony_elixir/local_tracker_test.exs test/symphony_elixir/core_test.exs test/symphony_elixir/extensions_test.exs`
- [x] `mix test test/symphony_elixir/local_issue_cli_test.exs test/symphony_elixir/dynamic_tool_test.exs test/symphony_elixir/app_server_test.exs`
- [x] `make -C elixir all`

### Notes

- 2026-03-19: Created `LOCAL-6` to track tracker-backed leasing for distributed local runs.
- 2026-03-19: Reproduction target is architectural rather than a flaky test: today multiple Symphony runtimes can race on the same `Todo` issue because claims only exist in orchestrator memory.
- 2026-03-19: `LOCAL-4` dynamic-tool work and `LOCAL-6` lease lifecycle work are both present on `feat/local-tracker-parallel-runtime`.
- 2026-03-19: Final validation passed with `233 tests, 0 failures`, `coverage 100%`, and clean `dialyzer`.
