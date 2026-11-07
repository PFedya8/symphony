# Symphony board: operator guide

This is an original Symphony board informed by the workflow shown in the README
video. It is **not Linear, a Linear clone, or a connected production agent system**.
The interface is functional: board edits, plans, checklists, links, approvals,
runs and history share one durable backend with the CLI.

## What works

- Six columns: **Backlog, Todo, In Progress, Human Review, Merging, Done**.
- Multiple tasks, project filtering, new tasks and direct task-detail links.
- Editable plans/checklists, task activity and links to existing PRs/walkthroughs.
- Preview, explicitly approved start, stop/hold and retry of the fixed simulator.
- Live updates between browser clients and CLI, revision checks and idempotency.
- SQLite persistence, restart recovery and one worker globally across projects.

A new database contains six **synthetic** tasks across `demo` and `sandbox`.
Their initial column placements are examples, not evidence of real work.
A simulated start moves its task to In Progress; simulated success moves it to
Human Review and records explicitly simulated evidence. It never closes a real
issue, creates a PR, merges, deploys or verifies a production release.

## Start locally

Requirements: Elixir 1.19.5 / OTP 28, Python 3 and native Exqlite build tools.
From the repository root:

```sh
cd elixir
mix setup
umask 077
export SYMPHONY_DEMO_DB="$(mktemp -d)/demo.sqlite"
export SYMPHONY_DEMO_TOKEN="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
# Optional, default 4000; valid range 1024–65535:
export SYMPHONY_DEMO_PORT=4000
mix run --no-start demo.exs
```

Open <http://127.0.0.1:4000/tasks> on that machine. Username: `demo`. Password:
the generated `SYMPHONY_DEMO_TOKEN`. Retrieve the token only in your private
terminal; never put it in a URL, screenshot, issue or committed file.
Keep the database path and token to restart this instance.

`127.0.0.1` is local to the device opening it. **This is not a phone-accessible
hosted URL.** The managed environment used for testing has no configured VPN or
supported authenticated preview ingress; no public tunnel was created.

## Use the board

1. Select a project, or leave **All projects** selected. On narrow screens, scroll
   the board horizontally to see additional columns.
2. Use **New task** to enter a title, project and description. It starts in Backlog.
3. Click a card to open its detail panel. The URL contains its task ID and can be
   reopened locally. Close the panel to return to the board.
4. Choose **Board stage → Move task**. This is a manual stage change; it does not
   execute, merge or deploy anything. Moving a task with an active run is rejected.
5. Expand **Edit plan** to enter one step per line. Saving a new plan resets its
   checkmarks. Toggle each step as it is reviewed. Plans are manually maintained,
   not fabricated agent reasoning or a claimed real-agent execution transcript.
6. Under **Run controls**, click **preview**, then **Approve and start simulation**.
   The fixed worker runs for three seconds. Click **Stop and hold** to interrupt it.
7. After stopping, **release-hold**, obtain a fresh **preview**, then select
   **Approve new retry**. A retry is a new run with a parent ID. Three attempts per
   task are allowed; only one worker can run across the whole instance.
8. Add an existing HTTPS PR or walkthrough link under **Pull requests &
   walkthroughs**. Links are labeled **user supplied; not verified**. The server
   does not fetch them or invent PR status. Click through to inspect the source.
9. Expand **Activity** entries for the durable structured event details. Run
   evidence is labeled simulated and has no real commit SHA.

Task edits change the task revision and invalidate old approvals. A replacement
preview for the same task invalidates the previous preview even without a revision
change. Previews for different tasks are independent. Each client checks only its
own approval; shared snapshots and activity omit approval credentials.

Stage changes to Merging or Done are manual organizational labels, not proof of a
merge or release. Done tasks cannot dispatch until moved back to another stage.
Resume is unsupported. Failed/interrupted runs require a fresh explicit retry.

## CLI: same state and commands

Use the same token and endpoint as the browser. Run from the repository root:

```sh
export SYMPHONY_URL=http://127.0.0.1:4000
cli/symphonyctl capabilities
cli/symphonyctl tasks board --json
cli/symphonyctl tasks list --project demo --json
cli/symphonyctl tasks show fixture-1
cli/symphonyctl tasks history fixture-1
cli/symphonyctl runs list --json
```

`tasks board` includes `board_revision`, task revisions, stages, runs and history.
For task creation, use the current **board_revision**. For other mutations, read
the selected task's **revision** immediately before issuing the command.
Replace `N` and `TASK_ID` below with those actual values:

```sh
cli/symphonyctl tasks create --title 'Review retry behavior' --project sandbox --description 'Inspect and verify the fixture' --revision N
cli/symphonyctl tasks move TASK_ID --stage Todo --revision N
cli/symphonyctl tasks plan TASK_ID --text 'Inspect constraints
Verify behavior
Review evidence' --revision N
cli/symphonyctl tasks check TASK_ID --step 0 --completed true --revision N
cli/symphonyctl tasks link TASK_ID --kind walkthrough --title 'Review notes' --url https://example.com/notes --revision N
cli/symphonyctl tasks start TASK_ID --dry-run --revision N
# Use the returned preview ID and the same task revision:
cli/symphonyctl tasks start TASK_ID --approval PREVIEW_ID --revision N --key start-attempt-1
```

The CLI creates a fresh UUID key on every invocation unless `--key` is supplied.
To replay after an uncertain response, use **the same explicit key and unchanged
arguments**, including revision and approval. A new intentional retry needs a new
key, current revision and fresh approval. Reusing a key with different arguments
is an idempotency conflict. The server infers the task from a run ID for `runs
stop` / `runs retry`; it rejects cross-task run or approval use.

Opaque IDs beginning with `-` remain unchanged, including these forms:

```sh
cli/symphonyctl --json runs stop -run --revision 2
cli/symphonyctl runs retry -run --revision 2 --approval -preview
```

These are syntax examples, not existing run IDs. CLI exit codes are 0 success,
1 transport/local error, 2 command conflict/usage and 3 authentication failure.
The authenticated API uses `/api/v1/control/snapshot`, optional `?task_id=ID`,
`/capabilities`, `/events?cursor=N` and POST `/commands`. Browser Basic Auth is
rejected for API mutations; the CLI uses bearer auth. The browser uses LiveView's
signed session and CSRF protection.

## Persistence, migration and boundaries

Stop with Ctrl-C; restart with the same database and token to retain state.
Unknown active work is marked interrupted after restart, never automatically
replayed. The existing orchestrator owns workers; no second scheduler was added.

**Database format is now version 3.** On opening a version-1 single-task database,
the launcher preserves its task/runs/history and adds board fields. It does not
inject six new sample tasks into an existing database. Old approvals are cleared.
Before upgrading, stop the old process and copy its database and any journal as a
private backup. Old binaries reject version 3; rollback requires the old backup.
Do not restore or copy over a live database. Unknown versions fail closed.

Limits: 100 tasks, 20 checklist steps (160 bytes each), 10 links per task, three
runs per task, one worker globally and 1,000 recorded commands/events. Titles are
limited to 160 bytes, project labels to 80, descriptions/plans to 4,000 and HTTPS
URLs to 2,000. A full command history refuses further mutations; start a fresh
private database for a new demonstration rather than deleting live state.

Project selection is **organizational filtering, not tenant authorization**.
Every authenticated operator of an instance can see/control all its projects.
For unrelated projects needing access isolation, use separate processes, private
databases and tokens, distinct local ports, and (for future real integration)
separate workspace roots and least-privilege tracker credentials. Never share a
SQLite file between processes. No credentials or external accounts were added.

## Integrations and verified limits

The repository has Linear, GitHub, GitLab, Jira, Asana and memory tracker adapters.
This board deliberately runs the **fixture** lifecycle; it does not import issues
or trigger those real adapters. Existing provider adapters are not automatically
multi-project sources for this board. Google Calendar and Google Tasks are absent.

GitLab's existing real adapter polls one configured `project_path` in pages of
100, refreshes issue IIDs and normalizes identifiers to `GL-<iid>`. It maps
`opened`/`closed` states, does not import dependencies, and has no webhook flow.
Its optional `gitlab_api` tool accepts raw GET/POST/PUT/DELETE paths with host-side
auth; those paths are not restricted to the configured project. Token permissions
are the actual boundary. No live GitLab scopes or credentials were tested here.

Future real integration should map tracker issues and actual runtime events into
these task/run projections while keeping the existing orchestrator as execution
owner. Plans and PR status must come from observed evidence, not fabricated
progress. A future Google Tasks adapter can use the existing tracker read
callbacks; Calendar should be a separate optional availability/presentation
integration. OAuth consent and mutations require explicit authorization.

This delivers the requested board/detail workflow, **not full parity with the
Linear video**: there is no real agent plan stream, automatic PR creation/status
sync, tracker import, multi-user permissions, or hosted mobile URL.
Desktop cards can be dragged to another stage; the accessible detail-panel
selector provides the keyboard/mobile alternative. Both use revision checks and
reject changes while a task has an active run. Canceled and Duplicate, like Done,
reject execution; Rework remains executable. Expand task opens a full-page detail. Existing dependency
advisories and disabled endpoint origin checking still require review before any
remote exposure. No production behavior or full two-minute expiry timing is claimed.

## Verification and screenshots

```sh
cd elixir
mix test test/symphony_elixir/demo_test.exs
make all
cd ..
python3 scripts/test_symphonyctl.py
# Requires a free local port; creates and removes its own database/server:
python3 scripts/check_manual_demo.py
```

With Playwright/Chromium installed, start a **fresh six-task disposable database**
and run `node scripts/capture_manual_demo.cjs` with its token. It mutates only
synthetic tasks, verifies desktop/mobile flows, and writes screenshots to
`/tmp/symphony-screenshots`. Optional `PLAYWRIGHT_CHROMIUM_EXECUTABLE` selects an
installed browser; `SYMPHONY_SCREENSHOTS` selects the output directory.

- [Desktop board](screenshots/board/01-board-desktop.png)
- [Desktop task detail](screenshots/board/02-task-desktop.png)
- [Mobile board](screenshots/board/03-board-mobile.png)
- [Mobile plan and run detail](screenshots/board/04-task-mobile.png)
- [Mobile evidence and activity](screenshots/board/05-evidence-mobile.png)

See [the board test report](BOARD_TEST_RESULTS.md) for results and limitations.
The older `screenshots/manual-demo` directory documents the superseded single-task UI.

### Concurrent editing and visible errors

Starting an edit pins that form to the revision you saw. Live updates continue,
but do not replace your draft or silently advance its revision. If another client
saves first, your save reports a conflict without overwriting their change. Copy
any text you want to keep, then choose **Reload current data (discard draft)**,
review the current data and submit a new edit. This applies to plan, stage and
link forms; task creation checks the board revision. Open editing sections stay
open during live updates.

Errors appear inside the active task panel, with an assertive alert and sticky
placement on small screens. Invalid plans, unsafe links and ineligible run
requests leave state unchanged. A project literally named `all` is supported;
**All projects** is a separate filter choice.

Run `node scripts/check_board_conflicts.cjs` against a separate fresh disposable
local database using the same token/browser environment variables as the capture
script. It exercises two actual browsers, stale plan rejection and recovery,
visible mobile plan/link/run failures, and the literal `all` project filter.

## Authored updates, discussion and walkthroughs

Open a task, then **Publish authored update**. Supply Plan, Acceptance Criteria
and Validation as plain text, one item per line. Two leading spaces create a
child; four create a grandchild. Do not skip levels. Each section allows 50 items,
500 bytes per item and 4,000 bytes total. Publishing preserves an immutable
version in Activity and shows the latest version in the task detail. This is
operator-authored content; it is not presented as an agent-generated plan.
The flat execution checklist remains separate.

Use **Post comment** for a new discussion entry. Select an existing comment in
**Reply to** to create a reply; threads support three levels. Comments are
plain text, not executable HTML/Markdown, and remain in durable activity.
There is one authenticated shared operator identity, not individual accounts.
Per task: 20 authored updates, 100 comments, 20 imported reports. There is no
comment edit/delete operation. Forms preserve drafts and reject stale revisions.

The same mutations work through `POST /api/v1/control/commands` and the CLI:

```sh
# Obtain a fresh revision before each mutation.
cli/symphonyctl tasks show fixture-1 --json
cli/symphonyctl tasks worklog fixture-1 --revision 1 \
  --plan-text 'Inspect behavior
  Check cancellation' \
  --acceptance-text 'No stale overwrite' --validation-text 'Two clients checked'
cli/symphonyctl tasks comment fixture-1 --revision 2 --text 'Please review'
# Use the returned comment id as --parent-id when replying.
```

Add a `walkthrough` HTTPS link. Supported Vimeo and YouTube URLs offer a **Load
walkthrough** button. No provider request happens before that click. The player
uses a canonical allowlisted origin, a sandbox, no referrer, and no autoplay or
clipboard permissions. Other providers remain ordinary external links. Playback
may be blocked by the provider's privacy settings, network rules or browser;
the integration never claims a linked recording is verified evidence.

## Explicit integration imports

These are real one-shot imports through the CLI and shared service. They do not
start an agent, create a PR, merge anything, change the stage or set
`release_verified`. Imported reports are labeled **operator imported; not
independently verified by service**, because the control API can also submit a
report. The server records the authenticated operator and receipt time.

**GitHub PR evidence:** `import-pr` performs a real GET against the canonical
GitHub REST API. Redirects are refused. It retains only title, state, merged/draft,
head/base SHA and update time; it excludes PR body and credentials.

```sh
cli/symphonyctl tasks import-pr fixture-1 --revision CURRENT_REVISION \
  --url https://github.com/PFedya8/symphony/pull/4
```

Public repositories work without a provider token. For a private repository,
the operator must supply an already-authorized `SYMPHONY_GITHUB_TOKEN` with read
access to that repository's pull requests. This is separate from the board token;
it is sent only to `api.github.com`, never persisted or forwarded to the board.
GitHub Enterprise and GitLab MR imports are not implemented by this command.
A new import is required to refresh status; there is no polling/webhook scheduler.

**Existing Symphony runtime:** the standard orchestrator already exposes
`GET /api/v1/:issue_identifier`. `import-runtime` reads that endpoint from an
explicit loopback-only source. It copies only issue identifier, status, state,
turn count and last event/type/time. Prompts, messages, workspace paths, logs,
provider credentials and session identifiers are excluded.

```sh
cli/symphonyctl tasks import-runtime fixture-1 --revision CURRENT_REVISION \
  --source-url http://127.0.0.1:4002 --issue PROJECT-123
```

The standard runtime must already be running with a configured workflow and
tracker. An inactive/completed issue absent from its transient observability API
returns an error; this is not a historical agent-output store. The fixture and
standard runtime are separate modes and cannot share one orchestrator process.
This import is read-only at the source, adds no scheduler, dispatches no work,
and does not establish a project mapping automatically.

**Reviewed agent output:** export a selected result from the actual agent's
workspace into a JSON file with `reference` and `summary` strings. Review it for
secrets before import. The reference should identify the run/commit/artifact;
the board does not authenticate that claim. Only those two fields are copied.

```sh
# reviewed-agent.json: {"reference":"run/commit/artifact identity", "summary":"Reviewed selected output"}
cli/symphonyctl tasks import-agent fixture-1 --revision CURRENT_REVISION \
  --file reviewed-agent.json
```

Input files are capped at 64 KiB; reference at 500 bytes and summary at 8,000 bytes.
Keep the board token with the operator/importer rather than giving an agent broad
board control. Importing an artifact is not a substitute for independently
reviewing its tests or merge status.

## Version 3 migration and validation

This increment writes snapshot schema **3**. Versions 1 and 2 gain empty authored
updates/comments/reports while preserving their tasks. Stop the instance and
back up SQLite before upgrading. Older binaries refuse schema 3; rollback needs
the pre-upgrade database backup. Separate project instances still require their
own token, database, workspace and authorized provider credentials.

Run `node scripts/check_board_content.cjs` against a fresh disposable local
fixture with the same environment variables as the earlier browser scripts.
It verifies nested sections, comments/replies, CLI/UI consistency, agent-artifact
import and opt-in embed boundaries. It blocks video traffic deliberately and
therefore does **not** verify provider playback.

### Recovering an import after a lost response

Choose and retain an explicit `--key` before the first import. Retry with the
same task, original revision, key and source arguments. The CLI first checks
`import-receipt` through the authenticated command API. If the import already
committed, it returns the stored receipt without opening the artifact file or
contacting GitHub/the runtime. This works when the source changed or disappeared.
A changed source observation requires a **new key and current task revision**.
Without explicit `--key`, each CLI invocation still generates a new UUID.

The server binds an import receipt to the source intent, task/run context,
original revision and authenticated actor. If concurrent source reads produce
different evidence under the same identity, the first committed report wins;
both callers get that receipt, with one revision increment and one activity event.
Different identities reusing a key conflict. Receipt reads themselves do not
write events, consume history capacity or reveal non-import/approval receipts.
The receipt and identity survive restart in SQLite; no local CLI cache is needed.

For API clients, `import_intent` is a 64-character lowercase SHA-256 digest of
the stable source selection. Send it with `op=evidence`, task/revision/key. Query
`op=import-receipt` with the same context before fetching; it returns `found=false`
or `found=true` with the original result. The server supplies the actor from
authentication. Direct evidence requests without `import_intent` retain strict
full-payload idempotency. Use a new identity/key for a genuinely new observation.

Receipts created before this change lack a source identity. Lookup fails closed
with `idempotency_conflict` for those keys; it neither guesses a match nor imports
again. Inspect existing task reports/history and reconcile the receipt manually.
Do not switch to a new key merely to bypass an uncertain earlier outcome.

Regression: `python3 scripts/check_import_replay.py` against a disposable local
fixture runs the real CLI against a mutable local HTTP source, then changes,
disables and removes that source. It asserts one source read, one stored report,
one revision increment and identical replayed receipts.
