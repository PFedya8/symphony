# UI reference gap and proposed scope

The review's description of the README video identifies a Linear board with
Backlog, Todo, In Progress and Human Review, plus task details containing an agent
plan, activity and a linked PR. This assessment uses that supplied description;
it does not claim a frame-by-frame video review or UI parity.

## Current Go fixture

One fixed task, one instance/project, manual preview/start/stop/hold/retry controls,
one-second snapshot polling, run lineage and JSON simulation evidence/history.
The existing CLI and browser share one backend. The task stays `opened` even after
a successful simulation. There is no real agent, tracker integration, code change,
PR creation or production release verification in the Go implementation.

## Missing compared with the reference

- A multi-task board, column/status mapping, project/task filters, ordering and
  task navigation; current fixture status cannot represent those four columns.
- A task detail view with structured agent plan, readable incremental activity,
  artifacts/checks, review state and verified linked PRs.
- Real tracked tasks and agent lifecycle integration. Styling the fixture into a
  board would not add that backend behavior.
- Incremental event delivery/pagination in the UI, connection/recovery indicators,
  long histories, loading/error/empty states and accessible mobile interactions.
- Product-level authorization, safe workflow transitions and project isolation for
  multiple real projects. Current separate processes are not multi-tenancy.

## Practical incremental plan (not implemented)

1. **Agree on the shared data contract and backend owner.** Extend the existing
   Elixir orchestrator/service for real execution rather than inventing a scheduler
   in the UI or presenting Go's simulator as a production replacement. Define task
   list/detail, canonical tracker state, run state, permissions, plan/activity and
   verified PR/evidence fields. Preserve the current CLI API or version additions.
2. **Build a read-only board and detail page.** Map real tracker statuses explicitly
   into configurable columns. Keep task state distinct from run state; a completed
   run must not automatically imply task completion or Human Review. Add fixtures
   for multiple tasks, but label them when live data is unavailable.
3. **Connect existing safe controls and evidence.** Use the same backend commands
   and revision/idempotency rules as the CLI. Add incremental events, run history,
   plans and PR links only when supplied by real backend evidence. Defer drag/drop
   writes until permissions and tracker state transitions have an explicit contract.
4. **Validate real workflows and project reuse.** Test UI/CLI consistency, recovery,
   stale revisions, capacity safeguards, mobile/accessibility, paging and a second
   project. Introduce production credentials only through authorized setup.

This is a separate product/UI workstream, not a visual polish change to PR #3.
Coordinate ownership with the existing UI/testing PR before modifying its routes,
components or deployment. No board/detail implementation is added here. A first
read-only board can be scoped independently; real plans, PR links and integrations
require backend work and must not be promised as fixture parity.
