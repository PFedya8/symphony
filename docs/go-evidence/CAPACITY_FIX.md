# Capacity safety follow-up

Independent review identified that the original unconditional 1,000-command guard
ran before command dispatch, so it blocked `hold` and `stop` as well as ordinary
writes. Reproduced against the Go PR's original implementation and the Elixir
baseline: seed 998 historical commands, execute preview (999), then start (1,000).
The next hold returned `demo_history_full` in **both** implementations. Since the
same guard precedes every mutation, active-run stop was blocked by it too.

The regression test failed before the fix:

- Go: `TestEmergencyControlsAtCapacity`: `hold at capacity: demo_history_full`.
- Elixir: expected `{:ok, _}`, received `{:error, "demo_history_full"}`.

## Fix and boundedness

Both backends now permit only effective safety transitions after ordinary capacity:
`hold` when not already held, and `stop` for a starting/running run. Exact-key replay
and conflict detection still happen first, followed by revision/task checks.
Scope/authentication and successful persistence remain mandatory. Results and audit
events are committed using the existing write-before-effect path.

At capacity, no release/start/retry can follow. Therefore there can be at most one
new hold plus one active-run stop, or **1,002 command records maximum** for normally
reachable state. Stop itself sets hold, so stopping first only needs one extra
record. Repeated no-op safety commands with fresh keys are rejected. Existing
idempotency records are never evicted; exact requests replay after restart.
The existing latest-1,000-event audit window remains unchanged, with monotone cursors
and durable safety events inside that window; this is not indefinite audit archival.

## Regression coverage

Both implementations test final-slot start, capacity rejection of ordinary writes,
hold then stop, restart, exact replay, conflicting reuse, bounded record growth,
durable stopped/held state, and the audit window/cursors. Both also test concurrent
fresh-key stops at capacity: one succeeds, the rest reject stale revisions, the
worker ends stopped, and no-op hold/stop cannot consume additional records.

Go race tests: 13 top-level tests passed, 82.9% statement coverage; vet passed.
The local build passed with `-buildvcs=false` because this managed worktree's Git
wrapper prevents Go's automatic VCS stamping. The Docker build from the earlier
PR validation also worked normally. This flag is used in the new CI build step.

Elixir `make all` passed after the fix: 312 tests, zero failures, six skipped;
configured coverage 100%, formatting/specs/Credo and Dialyzer all passed.

The original benchmark remains a measurement of the pre-fix fixture implementation.
Its ordinary low-volume workload never reached this limit; the resource comparison
has not been rerun for this targeted safety change.

## CI scope

`.github/workflows/go-manual.yml` adds Go formatting, vet, race/coverage tests and
build on all pull requests and pushes to main. Actions are pinned to commit hashes,
permissions are read-only, and checkout does not persist credentials. Existing CI
already runs Elixir `make all`. Browser checks and the cross-runtime contract remain
manual; branch-protection settings are not changed. GitHub execution status must be
checked separately from local success. The connected GitHub integration cannot
read repository Actions administrative permissions (HTTP 403); this does not
establish whether Actions are enabled or disabled.
