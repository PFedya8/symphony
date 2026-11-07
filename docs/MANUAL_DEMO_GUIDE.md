# Manual Symphony demo: use and verification

This guide applies to the Elixir fixture implementation from
`291937e7c26d7c5c89894238ae23cb18b4fe4653`, not the separate Go port.
It simulates a single task and at most three runs. It never executes Codex,
changes a repository, or deploys anything.

## Start a private local demo

Requirements: Elixir 1.19.5 / OTP 28 (see `elixir/mise.toml`), Python 3,
and the native build tools required by Exqlite. From the repository root:

```sh
cd elixir
mix setup
umask 077
# Choose a new private directory outside the repository for each fresh demo.
export SYMPHONY_DEMO_DB="$(mktemp -d)/demo.sqlite"
export SYMPHONY_DEMO_TOKEN="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
mix run --no-start demo.exs
```

Open <http://127.0.0.1:4000/tasks> on the same machine. The Basic Auth username
is `demo`; the password is the generated `SYMPHONY_DEMO_TOKEN`. Retrieve that
value only in your private terminal; do not paste it into an issue, screenshot,
URL or committed file. Keep it for CLI access and restarting the same demo.
The token is never included in the database's task history.

1. Click **preview** to obtain a two-minute approval for the current revision.
2. Click **Approve and start simulation**. A fixed worker runs for three seconds,
   then records `succeeded` with explicitly simulated evidence.
3. To interrupt it, click **Stop and hold** while it is running. The run becomes
   `stopped` only after worker termination; the task is held against dispatch.
4. Click **release-hold**, then **preview**, then **Approve new retry** to start
   a new attempt linked to the previous run. The total budget is three attempts.
5. The durable history below the run shows commands and worker events. A successful
   simulation does not mark the task completed or a production release verified.

Stop the server with Ctrl-C. Restart with the same database path and token to
retain history. Interrupted active runs are marked `interrupted`, never silently
replayed. To begin again after exhausting the budget, stop the server and choose
a new database directory. Never overwrite a database while its server is running.

## CLI

In a second terminal, set the same token and run from the repository root:

```sh
cli/symphonyctl capabilities
cli/symphonyctl tasks show fixture-1
cli/symphonyctl runs list --json
```

Read the current revision before any mutation. Example for a fresh database:

```sh
cli/symphonyctl tasks start fixture-1 --dry-run --revision 1
# Copy the returned approval id in place of PREVIEW_ID:
cli/symphonyctl tasks start fixture-1 --revision 1 --approval PREVIEW_ID --key start-fixture-1-attempt-1
```

The UI and CLI share the same service and SQLite store. Each command has an
idempotency key. **The CLI generates a fresh UUID on every invocation unless you
supply `--key`.** To repeat a request after an uncertain response, rerun the exact
command above with the same explicit key, approval, revision and arguments.
That returns its original result without dispatching another run. Do not refresh
the revision or approval for that replay; changing arguments under the same key
causes an idempotency conflict. A new intentional attempt uses `runs retry`, a
fresh preview/current revision, and a new key. A stale revision under a new key
is rejected. Approvals
are revision-bound and expire after two minutes. Browser Basic Auth is rejected
for API mutations; the CLI uses a bearer token. Opaque run IDs beginning with
`-` are accepted unchanged in commands such as `runs stop -run --revision 2`.

## Reproduce verification

Run with port 4000 free; the smoke check refuses an already-bound listener.
It creates and removes its own temporary database and token, and stops its own
server on completion. It does not mutate your running demo.

```sh
cd elixir
mix setup
mix test test/symphony_elixir/demo_test.exs
make all
cd ..
python3 scripts/check_manual_demo.py
python3 scripts/test_symphonyctl.py
```

The ExUnit suite covers lifecycle, concurrency/idempotency, worker loss, restart,
hold/retry budget, auth, unknown schema rejection and actual LiveView events
sharing run IDs with the HTTP CLI. The new process-level smoke check verifies
real HTTP auth and rendered HTML, approved start and duplicate replay, CLI parity,
simulated completion, and exact state/idempotency persistence across a server
restart. It is not a browser-rendering or production load test.

## Phone access and limits

`127.0.0.1` is local to the device opening it; this URL is not a phone-accessible
preview. The inspected managed environment has no configured VPN or supported
remote preview ingress. No public tunnel or production deployment was created.

Do not expose this development listener directly: the existing endpoint disables
browser origin checking, the fixture is a single shared control identity, and
the upstream progress document flags dependency advisories before remote hosting.
A future preview needs an approved authenticated HTTPS ingress, an explicit
allowed origin, dependency review, and a declared lifetime. It must expose only
synthetic fixture data, not the repository, environment, or arbitrary execution.

The three-run limit, unsupported resume, fixed fixture, lack of real tracker/agent
execution and no production release verification are intentional limitations.
Screenshots and recorded results accompany this PR when verified; they do not
establish that unsupported production behavior has been tested.

## Separate project instances

For independent pilots, copy/configure an instance per project. Assign each its
own process, private database directory, random control token, workspace root,
and tracker credentials. Do not share a SQLite file between running instances.
The demo launcher now accepts `SYMPHONY_DEMO_PORT` (1024–65535, default 4000),
while always retaining its loopback-only workflow. For example, run a second
fixture instance with a new database and token plus:

```sh
export SYMPHONY_DEMO_PORT=4001
mix run --no-start demo.exs
# In its corresponding CLI terminal:
export SYMPHONY_URL=http://127.0.0.1:4001
```

The second browser address is <http://127.0.0.1:4001/tasks>. Its commands, runs,
and approvals are isolated by its database and token. Both fixture instances
still display the fixed `demo` project and `fixture-1` task; configurable real
projects belong in the normal tracker/workflow configuration, not this simulator.
This is instance isolation, not tenant-aware access control within one process.
For real projects, follow `elixir/README.md` and `WORKFLOW.md`; use distinct
tracker project filters and workspace roots. No real tracker is contacted by the
demo, and real multi-project dispatch is not verified here.

Run the isolated smoke check on a second port with:

```sh
SYMPHONY_DEMO_PORT=4001 python3 scripts/check_manual_demo.py
```

## Integration status and extension points

Source inspection of this branch finds six tracker adapters: Linear, GitHub,
GitLab, Jira, Asana and memory. **Google Calendar and Google Tasks are not
implemented** (no registered adapter or implementation found in `elixir/lib`).
No external account was connected or credential created during these tests.

GitLab polling uses one configured `tracker.provider.project_path`, with optional
HTTPS `api_url` (default `https://gitlab.com/api/v4`) and an `api_key` environment
reference (default `GITLAB_PAT`). Active/terminal states are `opened`/`closed`.
It fetches project issues in pages of 100, refreshes individual project issue
IIDs, skips missing issues on refresh, and normalizes identifiers to `GL-<iid>`.
Dependencies are currently normalized to an empty list, so this adapter does not
import GitLab dependency relationships. No webhook integration is implemented.

The optional `gitlab_api` agent tool accepts GET/POST/PUT/DELETE relative REST
paths and executes them with host-side credentials. **Its raw API paths are not
restricted to the configured project**: the token's server-side permissions are
the real access boundary. Provider token variables are declared for removal from
the Codex child, but this does not turn the tool into a project sandbox. Use a
separate least-privilege credential per real project and review allowed mutations
before enabling agent tools. This change neither provisions nor validates live
GitLab scopes. Tests use synthetic responses; live API behavior is opt-in.

Proposed future Google Tasks support should implement the existing
`SymphonyElixir.Tracker` read callbacks and normalize one explicitly selected
list into `Tracker.Issue`; register it in the adapter map and validate provider
configuration. Keep OAuth refresh tokens host-side, declare secret environment
names, and start with read-only access. Add mutation tools only as an explicit,
separately authorized capability. Define deletion, completion, pagination and
error semantics in adapter contract tests before real dispatch.

Calendar is better treated as an optional availability/presentation integration,
not a competing task scheduler. Read selected calendars through a separate
credentialed boundary; any event creation should be an explicit user-authorized
action with idempotency and audit records. The existing orchestrator should
remain the sole execution owner. Calendar scopes, OAuth consent and event writes
are design work, not features supplied by this PR.

## Browser evidence (390 × 844)

Verified with Chromium and Playwright against a fresh local fixture. The browser
established a LiveView WebSocket, clicked preview/start, stopped and held the run,
released hold, requested a fresh preview and retried to simulated success. No
browser runtime errors were observed. These are actual screenshots, not mockups:

- [Initial task queue](screenshots/manual-demo/01-queue-mobile.png)
- [Stopped run and durable hold](screenshots/manual-demo/02-stopped-mobile.png)
- [Successful second attempt](screenshots/manual-demo/03-retry-succeeded-mobile.png)

To reproduce, install Playwright and its Chromium browser in your test tooling,
start a **fresh disposable demo**, and run from the repository root with its token:

```sh
# SYMPHONY_DEMO_TOKEN must match the disposable server, never your real credentials.
node scripts/capture_manual_demo.cjs
```

`SYMPHONY_URL` defaults to loopback port 4000. `SYMPHONY_SCREENSHOTS` defaults to
`/tmp/symphony-screenshots`; optional `PLAYWRIGHT_CHROMIUM_EXECUTABLE` selects an
existing Chromium binary. The script rejects non-loopback targets and a database
with existing runs, but it does mutate the fresh fixture it is given. Screenshots
contain synthetic approval/run IDs and events, never the authentication token.

Previews and approval controls are cleared when the task revision changes,
including changes from another client, when another preview replaces the approval
at the same revision, or when the preview expires. Each refresh checks only the
client's own approval with the service; shared snapshots/history omit approval
credentials. The validity response is a boolean, never another client's token. Obtain a
fresh preview after releasing hold. History and simulation evidence are collapsed
behind expandable summaries so raw JSON does not overwhelm the mobile page.
