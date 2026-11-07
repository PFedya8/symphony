# Multi-task board verification — 2026-11-07 UTC

Branch: `test/manual-demo-preview` (PR #2), extending the previously tested manual
fixture. Runtime: Elixir 1.19.5 / OTP 28.5.0.6 in the same official Elixir container
used for earlier checks. Native Chromium + Playwright exercised the UI through a
loopback-only relay; there was no public endpoint.

## Scope delivered

An original six-column board (Backlog, Todo, In Progress, Human Review, Merging,
Done), multiple tasks, project filtering, task creation and direct detail links.
Details provide manual stage transitions, editable checklists, approval/run
controls, persisted activity and user-supplied HTTPS PR/walkthrough links.
UI, API and CLI use the existing service and orchestrator. No competing scheduler,
real agent execution, external write or deployment was added.

## Results

| Check | Result |
| --- | --- |
| Full `make all` | Passed, including format, specs, strict Credo and Dialyzer |
| ExUnit | 317 tests, 0 failures, 6 opt-in live tests skipped |
| Measured coverage | 100% with existing repository exclusions unchanged |
| Dialyzer | 0 errors |
| Python CLI regression suite | 12 tests passed, including local HTTP argument checks and board command payloads |
| HTTP/CLI/restart smoke | Passed against a fresh isolated database on port 4001 |
| Desktop Chromium | Six columns/cards, project filter, detail navigation, start/stop/hold/retry, plan edit/check, evidence link and activity disclosure passed |
| Mobile-sized Chromium (390 × 844) | Cross-browser persisted state, board/detail views, task creation and stage move passed |
| Browser runtime errors | None observed |
| Diff whitespace | Passed |

The full gate used `HEX_OFFLINE=1` with already-installed locked dependencies to
avoid registry connectivity delays; it did not update dependencies or waive any
quality gate. Existing dependency advisories remain unresolved.

## Backend and parity evidence

The expanded ExUnit tests use real supervised OTP processes and SQLite storage.
They verify:

- Task creation, stage/plan/check/link edits and exact persistence after restart.
- Migration from a legacy version-1 single-task snapshot, preserving its task
  while adding board fields and clearing outstanding approvals.
- Task-specific approvals and retry lineage: a preview for task A cannot start B,
  a run cannot be stopped/retried as another task, and B's preview does not
  invalidate A's preview.
- Global worker capacity of one even across different tasks/projects, with
  independent per-task attempt counts.
- An active run blocks manual stage changes; simulated success moves only its own
  task to Human Review. A manually Done task rejects execution.
- Invalid stages, malformed checklist steps, unsafe link schemes/credentials,
  stale revisions, 100-task/10-link/20-step limits and unknown database versions.
- Board project filtering, creation and editing through LiveView; the real Python
  HTTP CLI reads identical task/checklist/link state and moves the same card.
- The pre-existing idempotency, crash recovery, stop/hold, authentication,
  cross-client invalidation and capability-redaction regressions still pass.

The browser capture script starts from six seeded synthetic tasks. It runs a
simulation, stops it, retries to simulated success, edits the plan, checks a step,
and attaches PR #2 as an explicitly user-supplied reference (not an assertion
that this task created or verified that PR). A second mobile-sized page reads the
persisted state, creates another task and moves it to Todo.

## Actual screenshots

- [Desktop board](screenshots/board/01-board-desktop.png)
- [Desktop detail](screenshots/board/02-task-desktop.png)
- [Mobile board](screenshots/board/03-board-mobile.png)
- [Mobile detail](screenshots/board/04-task-mobile.png)
- [Mobile evidence/activity](screenshots/board/05-evidence-mobile.png)

These are browser captures, not designs or mockups. They contain only synthetic
tasks and an explicitly supplied repository PR link. No login token appears.
The screenshots show the current board; older single-task screenshots remain
historical evidence in `screenshots/manual-demo`.

## Limits and remaining work

This is a functional fixture board, **not full parity with the Linear video**.
Plans are manually maintained; the three-second worker is a fixed simulator.
Tracker import, actual agent-generated plans, automatic PR creation/status sync,
drag-and-drop, Calendar/Google Tasks, tenant permissions and hosted phone access
are not implemented or verified. Column transitions use a selector. No real issue
was closed, PR merged or production release verified.

Project selection is a filter under one shared operator identity. Separate
instances/tokens/databases are required for access isolation. All links remain
unverified and are never fetched by the server. The Go comparison implementation
has not been ported to this new board/schema by this PR.

The schema is now version 2. Back up an old database while stopped before opening
it with this version; rollback needs the version-1 backup. Unknown active runs
are interrupted on restart, not automatically adopted or replayed. The suite
checks expiry handling but does not wait two minutes to verify real wall-clock
expiry end to end. Real-device Safari/accessibility audits and production load
measurements remain outside the verified scope.
