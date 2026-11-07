# Board contract for Elixir and other implementations

The HTTP/CLI contract is shared by fixture and opt-in GitLab runtime modes. This
file describes the Elixir implementation; another implementation must explicitly
advertise its supported mode. It does not imply Go has runtime support.

- Existing `/api/v1/tasks` and task command routes, revision checks, actor ownership,
  idempotency keys and approval requirements remain in force. See the CLI help
  and manual guide for payload examples. Do not share SQLite files across languages.
- Runtime snapshots advertise `mode: gitlab_runtime`; capabilities advertise
  `simulated: false` and the existing orchestrator as execution owner. Fixture
  mode remains simulated. Runtime issue IDs are the provider issue IDs, scoped to
  one configured GitLab project/instance; `native_ref` preserves project and IID.
- Existing polling discovers issues automatically (maximum 100 stored tasks).
  Runtime task creation and source synchronization commands are unavailable.
  Local stage/plan/comment/evidence edits use the same durable API as the UI.
- Preview binds the task revision and source digest. Start/retry requires a fresh
  preview and reserves one run before the existing scheduler spawns a worker.
  The source is fetched again and the full issue digest checked before dispatch.
  Source changes or unavailability prevent new execution. No automatic retry or
  continuation is scheduled. One worker globally; at most three attempts per task.
- Run states: authorized, starting, running, stopping, succeeded, failed, blocked,
  interrupted, stopped. Active runs recover as interrupted after restart. Starting
  and retrying require new human consent; restarting never resumes a reservation.
- Exact start/retry/stop receipt replays precede provider reads and have no repeated
  effects, even if the provider is offline. Different payloads with the same key
  conflict. Existing import receipt recovery semantics also remain unchanged.
- `runtime-start` is internal only and rejected at the public command boundary.
- Worker observations contain bounded event type/turn count and provenance, not
  raw prompts/logs/session identifiers/workspace paths. Normal worker exit moves
  a task to Human Review, never verified merge. Closed source issues become Done;
  `release_verified` remains false. Local stage edits do not write GitLab.
- Board-bound GitLab tools allow GET only for the configured project's issue/MR
  resources, notes, changes, commits and discussions. No arbitrary API paths,
  other projects or provider mutations. Generic non-board behavior is unchanged.
- `runtime_error: runtime_scope_changed` fences execution after configuration or
  credential changes. Restart clears approvals; project/endpoint/path changes
  require a fresh database and dedicated workspace root. Schema 4 persists scope.
- Authenticated loopback access only. Project filters are not tenant permissions.
  Multiple projects require separate instances, database, workspace, token and port.

Contract changes should be coordinated through PR review before another runtime
implements this mode. Synthetic tests exercise actual Elixir orchestration;
no live GitLab/Codex interoperability is asserted by this document.
