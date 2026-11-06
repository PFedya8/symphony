# Manual fixture slice

Baseline: 8f18afa81c8150d72860958365c659b0a6080c81, fast-forwarded from the
published environment's be10a1b checkout. The only upstream change was the handoff.

Verified baseline: `tracker.ex` lists six adapters including memory, no Redmine.
`orchestrator.ex` initializes in-memory blocked state, polls automatically, and
starts tasks under `AgentRuntimeSupervisor` (one_for_all). `workspace.ex` removes
terminal workspaces. `observability_api_controller.ex` refresh invokes the
orchestrator, so it is disabled in demo mode. `agent_runner.ex` launches the Codex
protocol; the demo never calls it. Existing `DashboardLive` is observability only.

Implementation decisions:

- Existing Orchestrator selects an explicit demo lifecycle at boot. No second
  scheduler. The existing one_for_all supervision fences workers on owner failure.
- One SQLite connection with exclusive locking, FULL synchronization, versioned
  snapshot and atomic writes. This deliberately small fixture store is bounded to
  1,000 commands/events and three runs; it is not a scalable tracker cache.
- Every mutation uses revision checks and persistent idempotency, with preview
  approval bound to revision, scope and expiry. Only one active run; no automatic
  retries. Stop records intent/hold and confirms process DOWN. Recovery marks
  active records interrupted without adopting PIDs or replaying unknown outcomes.
- One capability-scoped demo control token, bearer for CLI, Basic login for browser
  (username demo). LiveView uses signed session/CSRF. Bind loopback only. This is
  not a remotely deployable authenticated preview or multi-user permission model.
- Simulator has fixed code, no arbitrary tool, shell, filesystem or network access,
  and no child processes. It emits only structured fixed messages, never supplied
  text/secrets. No workspace is created or deleted; real workspace preservation,
  process-tree sandboxing and arbitrary-output redaction need later integration.
- SQLite schema 1 creates new state only; unknown versions fail closed. No schema
  upgrade is provided. Stop the runtime, copy the database and journal together
  before future migration/rollback. Never restore over a live owner.

Run locally (Elixir 1.19 / OTP 28):

```
cd elixir
mix deps.get
# Set SYMPHONY_DEMO_TOKEN securely to a random value of at least 32 bytes.
export SYMPHONY_DEMO_DB=/absolute/private/path/demo.sqlite
mix run --no-start demo.exs
```

Open `/tasks` on the local listener, username `demo`, configured token as password.
CLI uses the same `SYMPHONY_DEMO_TOKEN`, optional `SYMPHONY_URL` (default loopback).

```
cli/symphonyctl capabilities
cli/symphonyctl tasks show fixture-1
cli/symphonyctl tasks start fixture-1 --dry-run --revision 1
cli/symphonyctl tasks start fixture-1 --revision 1 --approval PREVIEW_ID
cli/symphonyctl runs list --json
cli/symphonyctl runs logs RUN_ID --follow
```

Read the current revision before mutations. After stop, release hold, preview again,
then `runs retry RUN_ID --revision N --approval PREVIEW_ID`. Retry is a new run.
Resume explicitly fails. API works without any connected UI. CLI exit codes:
0 success, 1 transport/local error, 2 command conflict/usage, 3 authentication.

Pending beyond fixture slice: real GitLab import/outage/rate-limit handling,
weekly selection, rich dependencies/cycles, workspace and OS process-tree policy,
read-only credentials/multi-user auth/revocation, untrusted log sanitization,
waiting/input simulation, large-history pagination, full resource benchmark,
remote hosting and Mac package. No production action, commit, push or deployment
is performed. See validation results below; unrun checks are not passing evidence.

Source references in this checkout: adapter registry `elixir/lib/symphony_elixir/tracker.ex:13`;
execution owner boot `elixir/lib/symphony_elixir/orchestrator.ex:55`;
shared command handler `elixir/lib/symphony_elixir/orchestrator.ex:1426`;
one-for-all supervisor `elixir/lib/symphony_elixir/agent_runtime_supervisor.ex:15`;
workspace creation `elixir/lib/symphony_elixir/workspace.ex:15`;
refresh `elixir/lib/symphony_elixir_web/controllers/observability_api_controller.ex:28`.

Resource smoke evidence is saved in `bench/smoke-result.json`: development startup
0.54 s, idle 97.2 MiB RSS / 0.30% of a core over 10 s; one simulated worker 97.1 MiB /
0.50% over 2 s; one CLI request including Python startup 43 ms. This is not evidence
for the proposed full production budget. The simulator is an OTP task inside the
coordinator, not an independent OS agent subtree. UI/browser memory is unmeasured.

The fixture deliberately does not persist arbitrary hold-reason text; CLI rejects
`--reason` explicitly. Logs are fixed structured events, not real-agent output.
Existing locked dependencies report Hex security advisories; dependency remediation
and review are required before remote hosting. No unrelated dependency upgrades
were made (only exqlite and its db_connection dependency were added).

Three existing retry-timing tests were changed to use the memory tracker because
their default Linear fixture attempted network requests and consumed their timing
windows. Assertions and production retry logic were preserved.

## Final validation

- `mix test test/symphony_elixir/demo_test.exs`: 11 tests, 0 failures.
- Final `make all`: exit 0; 310 tests, 0 failures, 6 opt-in live tests skipped;
  100% measured coverage using the repository's existing exclusions and threshold.
  Build, format check, specs check, strict Credo and Dialyzer passed (0 errors).
- LiveView/real HTTP CLI parity test starts from the UI, reads the identical run ID
  using the Python client, stops through that client, and observes the UI/history.
- Lifecycle tests cover duplicate concurrent commands, stale approval/revision,
  hold and crash recovery, worker failure, retry lineage/exhaustion, unsupported
  resume, forbidden scope/cross-task commands, auth rejection, cursor reconnect,
  and fail-closed unknown database schema.
- `python bench/smoke.py` started the real local application, made authenticated
  requests and a CLI request, measured it, then terminated the process.
- Python syntax checks and `git diff --check` passed.

Acceptance limits: no real tracker outage/rate-limit test, hostile subprocess tree,
workspace changes, real secret-bearing agent logs, expired-approval clock test,
waiting-for-input scenario, browser renderer resource measurements, complete
benchmark workload, remote preview or macOS packaging is claimed verified. These
remain work before expanding the fixture into a real operational pilot. No commits,
pushes, merges, deployments or environment publication were performed.
