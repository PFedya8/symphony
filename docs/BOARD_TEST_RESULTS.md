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
UI, API and CLI use the existing service and orchestrator. The opt-in GitLab
runtime mode now connects issue discovery and approved AgentRunner execution.
No competing scheduler, live provider write or deployment was added.

## Results

| Check | Result |
| --- | --- |
| Full `make all` | Passed, including format, specs, strict Credo and Dialyzer |
| ExUnit | 354 tests, 0 failures, 6 opt-in live tests skipped |
| Measured coverage | 100% with existing repository exclusions unchanged |
| Dialyzer | 0 errors |
| Python CLI regression suite | 19 tests passed, including local HTTP argument checks and board command payloads |
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
The first five captures show the expanded workflow board; captures six and seven show the
concurrent-edit and mobile-feedback fixes. Older single-task screenshots remain
historical evidence in `screenshots/manual-demo`.

The concurrency regressions first failed against the earlier board implementation.
Two independent LiveView clients now verify that a stale submitted form cannot
overwrite another client, including after a broadcast updates its surrounding UI.
The actual Chromium regression (`scripts/check_board_conflicts.cjs`) additionally
verifies that editing disclosures stay open, drafts survive DOM patches, explicit
reload takes effect, and mobile errors are not obscured by the full-screen panel.

## Limits and remaining work

The default fixture and opt-in runtime board are **not full parity with the Linear video**.
Plans and authored sections are manually maintained. The fixture worker is simulated;
the runtime mode uses the actual AgentRunner with explicit human approval.
Actual agent-generated plans, automatic PR creation/status sync,
Calendar/Google Tasks, tenant permissions and hosted phone access
are not implemented or verified. Column transitions use drag-and-drop or an accessible selector. No real issue
was closed, PR merged or production release verified.

Project selection is a filter under one shared operator identity. Separate
instances/tokens/databases are required for access isolation. All links remain
unverified and are never fetched by the server. The Go comparison implementation
has not been ported to this new board/schema by this PR.

The schema is now version 4. Back up an old database while stopped before opening
it with this version; rollback needs the pre-upgrade backup. Unknown active runs
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
| Authored nested Plan, Acceptance Criteria, Validation in activity | Immutable authored updates with three nested levels and durable activity; shared API/CLI/UI | Operator authored, not automatic agent-generated content |
| GitHub PR and walkthrough | Real one-shot GitHub PR API import; HTTPS links; opt-in Vimeo/YouTube embeds | No automatic PR creation/status synchronization; provider playback not verified |
| Replies and comments | Durable three-level plain-text threads; authenticated shared operator; bounded resources | Individual users, edit/delete and moderation workflow not implemented |
| Agent workflow and merge completion | Fixture simulation or runtime worker exit moves its own task to Human Review; operators may move Merging/Done | Opt-in GitLab discovery and approved AgentRunner are connected; live validation and PR/merge sync remain unavailable |

The shared service now includes these authored sections, comments and reports.
Existing runtime observation can be imported from its loopback issue API without
copying raw agent messages, logs or workspace paths. Reviewed agent artifacts
have a separate bounded import path. These are explicit one-shot operations,
not a new scheduler or automatic live agent/PR integration.

## Authored content and integration verification

- Actual Chromium: nested sections, published activity, comments/replies,
  UI/CLI parity, reviewed synthetic agent artifact import, desktop/mobile views.
- Actual GitHub API: imported public PR #4 using `tasks import-pr`, then verified
  its provider/reference/receipt provenance and visible report in the UI. This
  was a read-only source request and a local fixture write, not a merge.
- Runtime import: exercised the actual HTTP importer against a synthetic local
  server using the existing Presenter issue contract. No configured production
  runtime/real Codex session was available, so live agent integration is untested.
- Video embed: proved no iframe/provider request before opt-in, exact canonical
  source and sandbox/referrer policy after opt-in. The provider request was
  aborted by the browser test; playback is explicitly untested.
- ExUnit: restart persistence, legacy schema-2 migration, HTML escaping,
  cross-task reply rejection, nesting/resource bounds, authored history,
  provider URL rejection and real CLI round trips.
- Python: selected artifact fields, bounded input, canonical GitHub requests,
  excluded secrets/body, redirect rejection, local-runtime HTTP import and
  unsafe source refusal; existing opaque-ID regressions retained.

New actual screenshots:

- [Nested authored plan](screenshots/board/08-authored-plan-desktop.png)
- [Mobile comments/replies](screenshots/board/09-comments-mobile.png)
- [Imported artifact and opt-in walkthrough](screenshots/board/10-imports-walkthrough-mobile.png)
- [Actual public GitHub PR API import](screenshots/board/11-github-import-desktop.png)

The first full gate attempt hit an existing core retry-timer test's five-second
`:sys.get_state` timeout. That unchanged test passed immediately in isolation;
the full gate then passed without weakening the test or quality checks.

## Import replay recovery

The independent failure reproduced before the fix: repeating a successful
runtime import with the same key/revision after its source turn count changed
returned `idempotency_conflict`. The regression now passes through the actual CLI
and HTTP control API: changed, unavailable and removed sources all replay the
original receipt, with exactly one source read and one report/revision write.

Service tests also cover concurrent differing observations, restart recovery,
actor/task/revision/source mismatch conflicts, invalid lookup requests, and
refusal to expose preview capabilities or infer identities for legacy receipts.
Python tests cover receipt-first ordering for runtime, GitHub and file imports
and matching identity propagation from lookup to commit. Historical imports
without source identities retain their strict old semantics and fail closed on
lookup; the guide explains safe manual reconciliation.

## Opt-in GitLab runtime integration

`RuntimeBoard` is durable state owned by the existing Orchestrator, with no second
process scheduler. The existing tracker poll discovers issues; actual AgentRunner
workers require a fresh human preview and source-bound approval. Synthetic provider
and Codex protocol tests cover real process/workspace lifecycle, receipt replay
while the provider is offline, fresh-source invalidation, stop/hold, restart,
configuration fencing, isolated database/workspace ownership, read-only scoped
provider tools and the existing shared authoring/UI/API contract.

Reproduction: `mix test test/symphony_elixir/runtime_board_test.exs`, then the full
`make all` gate. The guide includes the separate local browser fixture commands.
`node scripts/check_runtime_board.cjs` passed against that loopback fixture with
no browser errors: automatic source discovery, no unapproved launch, observed
running/completed state, actual stop/hold and API/UI identity. The fake protocol
process exercises actual AgentRunner plumbing; it is not a real Codex model run.

- [Runtime board, desktop](screenshots/board/12-runtime-board-desktop.png)
- [Observed worker, mobile viewport](screenshots/board/13-runtime-worker-mobile.png)
- [Observed completion, desktop](screenshots/board/14-runtime-completion-desktop.png)

No live GitLab account, real Codex account, production repository checkout or public
endpoint was used. Required live configuration and remaining integration gaps are
listed in the operator guide. The Go compatibility boundary is documented in
[BOARD_API_CONTRACT.md](BOARD_API_CONTRACT.md); this PR does not implement Go support.

## Independent safety-review remediation

Synthetic regressions cover actual child environments (including post-login-profile
unset), token aliases, SSH clients, and rejection of child-derived empty credentials
by the board auth boundary while the real synthetic operator token still works.
Real external worker/background-child and checkout-hook tests verify delayed writes
do not happen after stop or orderly shutdown. The process owner also covers worker
death, supervisor shutdown, partial stdout, and failed startup handshake. Hot reload
from autonomous mode to board mode never dispatches a new issue without restart.
Existing sessions lose preview/comment/navigation/update access after token or
configuration changes, and stored approvals are cleared. GitLab API URL environment
resolution is tested using the exact form shipped in the workflow example.

These are local synthetic checks, not hostile-process containment or live provider
validation. The guide documents process-group and host-isolation limitations.
