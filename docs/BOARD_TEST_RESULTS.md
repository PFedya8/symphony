# Multi-task board verification — 2026-11-07 UTC

Branch: `feat/manual-task-board`, following the previously tested manual
fixture in merged PR #2. The board commit is not part of that earlier merge. Runtime: Elixir 1.19.5 / OTP 28.5.0.6 in the same official Elixir container
used for earlier checks. Native Chromium + Playwright exercised the UI through a
loopback-only relay; there was no public endpoint.

## Scope delivered

An original nine-column board (Backlog, Todo, In Progress, Human Review, Merging,
Done, Rework, Canceled and Duplicate), multiple tasks, project filtering, task creation and direct detail links.
Details provide manual stage transitions, editable checklists, approval/run
controls, persisted activity and user-supplied HTTPS PR/walkthrough links.
UI, API and CLI use the existing service and orchestrator. No competing scheduler,
real agent execution, external write or deployment was added.

## Results

| Check | Result |
| --- | --- |
| Full `make all` | Passed, including format, specs, strict Credo and Dialyzer |
| ExUnit | 321 tests, 0 failures, 6 opt-in live tests skipped |
| Measured coverage | 100% with existing repository exclusions unchanged |
| Dialyzer | 0 errors |
| Python CLI regression suite | 12 tests passed, including local HTTP argument checks and board command payloads |
| HTTP/CLI/restart smoke | Passed against a fresh isolated database on port 4001 |
| Desktop Chromium | Nine columns, drag/drop with persisted counts, project filter, expanded detail navigation, start/stop/hold/retry, plan edit/check, evidence link and activity disclosure passed |
| Mobile-sized Chromium (390 × 844) | Cross-browser persisted state, board/detail views, task creation and stage move passed |
| Concurrent Chromium clients | Stale plan rejected; draft and original revision preserved; explicit reload and reviewed save passed |
| Mobile failure feedback | Invalid plan, invalid link and ineligible run alerts visible inside the active panel; viewport and occlusion checks passed |
| Reserved project name | Literal `all` shows only its project; All projects restores every card |
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
- [Mobile stale draft conflict](screenshots/board/06-mobile-stale-draft.png)
- [Mobile invalid link feedback](screenshots/board/07-mobile-invalid-link.png)

These are browser captures, not designs or mockups. They contain only synthetic
tasks and an explicitly supplied repository PR link. No login token appears.
The first five captures show the expanded workflow board; the last two capture the
concurrent-edit and mobile-feedback fixes. Older single-task screenshots remain
historical evidence in `screenshots/manual-demo`.

The concurrency regressions first failed against the earlier board implementation.
Two independent LiveView clients now verify that a stale submitted form cannot
overwrite another client, including after a broadcast updates its surrounding UI.
The actual Chromium regression (`scripts/check_board_conflicts.cjs`) additionally
verifies that editing disclosures stay open, drafts survive DOM patches, explicit
reload takes effect, and mobile errors are not obscured by the full-screen panel.

## Limits and remaining work

This is a functional fixture board, **not full parity with the Linear video**.
Plans are manually maintained; the three-second worker is a fixed simulator.
Tracker import, actual agent-generated plans, automatic PR creation/status sync,
Calendar/Google Tasks, tenant permissions and hosted phone access
are not implemented or verified. Column transitions use drag-and-drop or an accessible selector. No real issue
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

## README video comparison

This comparison uses the observed behavior supplied by the independent reviewer,
not a claim of pixel or runtime parity with Linear.

| Observed video behavior | Current implementation | Remaining dependency or gap |
| --- | --- | --- |
| Drag cards and update counts | Desktop native drag/drop calls shared `move`; counts update after persisted success | Touch uses stage selector; no optimistic movement |
| Backlog/Todo/In Progress/Human Review/Merging/Done, Rework/Canceled/Duplicate | Nine persisted stages, available through UI/API/CLI | No automatic real merge or release verification |
| Full-page task detail | Expand task toggles a full-width view with the existing shared task state | Original Symphony styling, not Linear parity |
| Authored nested Plan, Acceptance Criteria, Validation in activity | Editable flat checklist, description and durable command activity | No rich authored activity document or nested sections |
| GitHub PR and walkthrough | HTTPS links supplied by operator and labeled unverified | No automatic PR creation/status synchronization; no embedded media |
| Replies and comments | Not implemented | Requires persisted authored comments, identity semantics and moderation/resource limits |
| Agent workflow and merge completion | Fixed simulator moves its own task to Human Review; operators may move Merging/Done | Real agent/tracker/PR integration and verified merge transitions are not connected |

A safe next increment would add bounded authored sections/comments to the shared
service, snapshot schema, HTTP and CLI before the UI. Real PR synchronization
then needs a repository mapping, authorized connector, webhook/poll ownership and
reconciliation tests. Arbitrary media is currently linked rather than embedded;
a future embed needs explicit provider handling and content/security controls.
