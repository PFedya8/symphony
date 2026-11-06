# Go manual fixture service

This is a Go port of the **manual fixture slice**, not a port of Symphony's full
Elixir tracker/orchestrator/Codex runtime. It never executes shell commands,
changes repositories, contacts trackers, or deploys anything. One backend owns
SQLite, commands, timers and audit history. The web UI and existing Python CLI
both call that backend; neither owns a scheduler or task database.

## Run

Requires Go 1.25+, a C compiler (SQLite uses CGO), and Python 3 for the existing CLI.
From the repository root:

```sh
cd go-manual
go build -o ../bench/go-manual .
cd ..
export SYMPHONY_DEMO_TOKEN="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
export SYMPHONY_DEMO_DB=/tmp/symphony-demo/state.sqlite
export SYMPHONY_GO_ADDR=127.0.0.1:4001
export SYMPHONY_PROJECT=demo
./bench/go-manual
```

Open `http://127.0.0.1:4001/tasks` and enter the same token. The static login page
contains no task data. API calls require a bearer token; the browser keeps it only
in page memory. Do not put it in URLs or commit it. Only literal loopback listen
addresses are accepted. Remote/public hosting is not part of this PR; use an
explicitly configured authenticated tunnel or reverse proxy for a remote demo.

1. Click **preview** to request a two-minute fixture approval.
2. Click **Approve and start simulation**. A timer completes after three seconds.
3. To interrupt, click **Stop and hold**. Release the hold before another preview.
4. Click **Approve new retry** after preview to create a new linked attempt.
5. There are three attempts maximum per fixture. Resume is deliberately unsupported.

The task remains `opened` after simulated success, and release verification stays
false. Evidence explicitly says no real code or deployment was verified. UI polling
refreshes every second; it is not Phoenix LiveView.

For the CLI, in another terminal with the same token:

```sh
export SYMPHONY_URL=http://127.0.0.1:4001
python3 cli/symphonyctl capabilities --json
python3 cli/symphonyctl tasks show fixture-1 --json
python3 cli/symphonyctl tasks start fixture-1 --dry-run --revision 1 --json
# Copy the returned approval id, and use the current task revision:
python3 cli/symphonyctl tasks start fixture-1 --approval APPROVAL_ID --revision 1 --json
python3 cli/symphonyctl runs list --json
```

Mutations require a current revision and unique idempotency key. Reusing the exact
same key/payload returns its original response, including after restart; changing
the payload with that key is rejected. Preview does not increment the revision.
Hold, release, start, retry and stop do. API errors carry `error.code` and use 409
for lifecycle conflicts, 401 for authentication, and 503 for storage failures.

## How it works and how state survives

A service mutex serializes requests and worker transitions. Each mutation clones
state, checks safeguards, writes the complete snapshot to SQLite with synchronous
FULL and exclusive locking, then installs it and starts/cancels its timer. Failed
writes leave the prior in-memory state intact. Async write failure makes the service
fail closed until restart. A second owner of the same database is rejected.

Restart marks active runs `interrupted`; it never silently reruns them. Holds,
audit events, command responses, revisions and approvals survive. Stop the service
before copying its database for backup. Never share one DB between Go and Elixir:
although the storage table is similar, idempotency fingerprints and recovery
implementations are not an interchange/migration contract. There is no import tool.

History retains the latest 1,000 events and normally accepts 1,000 commands.
At capacity, ordinary writes are rejected, but an effective hold and an active-run
stop remain available (at most two additional durable command records). New no-op
holds/stops and release/retry/start are rejected. Exact-key replays still return
the original result; no command records are evicted. Authentication, revision
checks and successful storage remain required for safety actions. For a fresh disposable demo, use a **new database
path**. Keep old databases if you need their history.

## A second project

Use one process per project, with a distinct token, database and port:

```sh
SYMPHONY_PROJECT=project-beta \
SYMPHONY_GO_ADDR=127.0.0.1:4002 \
SYMPHONY_DEMO_DB=/tmp/symphony-beta/state.sqlite \
SYMPHONY_DEMO_TOKEN="$(python3 -c 'import secrets; print(secrets.token_hex(32))')" \
./bench/go-manual
```

The configured project name is persisted and checked on restart: opening the
same database under a different name fails. Each instance still has the same
synthetic `fixture-1`; its identity is scoped by the instance/project. This is
configuration and data isolation, not multi-tenancy, OS sandboxing, repository
onboarding, or Google/GitLab integration. Users sharing the same OS account may
read that account's data. Real projects need separate Elixir workflows, workspace
roots and provider credentials; see [integration notes](../docs/GO_INTEGRATIONS.md).

## Validation and evidence

```sh
cd go-manual
go test -race -cover ./...
go vet ./...
test -z "$(gofmt -l *.go)"
```

Tests cover concurrent idempotency/start races, stale revisions, approval expiry,
retry budget, stop/hold, restart reconciliation, durable replay, storage failures,
exclusive ownership, two-project isolation, HTTP authentication and malformed input.

Browser check (verified with Playwright 1.62.1 and Chromium 156; install them in
your own tooling environment, and start a **fresh** Go database using the run instructions first):

```sh
SYMPHONY_DEMO_TOKEN="$SYMPHONY_DEMO_TOKEN" node bench/ui-check.cjs
```

Run that command from the repository root. Set `CHROMIUM_PATH` if needed. It checks
real UI behavior and writes [desktop](../docs/go-evidence/03-retry-succeeded.png)
and [mobile](../docs/go-evidence/04-mobile.png) screenshots. The screenshots show
synthetic fixture data and no token. They do not establish every possible behavior
or production readiness. See [benchmark method/results](../bench/GO_COMPARISON.md).

GitHub Actions now runs Go formatting, vet, race/coverage tests and a build on
pull requests and pushes to main (`.github/workflows/go-manual.yml`). Browser and
cross-runtime contract checks remain manual; branch-protection enforcement is not
configured by this PR.
