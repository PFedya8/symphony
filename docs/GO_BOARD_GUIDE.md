# Use the Go board

Build and run using [go-manual/README.md](../go-manual/README.md). Open
`http://127.0.0.1:4001/tasks`, enter the instance token, and select a card.
Refresh disconnects; tokens stay only in page memory. The loopback URL is not a
public phone preview; exposing it requires a separately authorized authenticated
access setup. This PR does not deploy a public instance.

Create tasks from **New task**. Move cards with drag/drop or the detail stage
selector on mobile. Search and project filters organize local fixture labels;
they do not grant or restrict access. Use separate instances for real projects.

Task details contain editable plan steps/checklists, nested Plan / Acceptance
Criteria / Validation documents, comments with replies (three levels), links,
imported evidence, runs and a durable activity history. Use two spaces per nested
worklog level, up to two nested levels. Plans and reports are plain text; markup
is not executed. Links require HTTPS without embedded credentials. Linked PRs
are user supplied and unverified. Allowlisted video embeds load only after a
click. Other URLs remain links.

Drafts keep the revision at which editing began. If another tab or CLI changes
the task, submitting the old draft yields `stale_revision`. Your draft remains;
use **Reload current data (discard draft)** only when ready to discard it.

For fixture execution, request **preview**, review the scope, then approve a
simulation. Stop holds the task; release the hold and obtain a new preview before
retrying. Three attempts per task, one active simulation across the board. A
successful timer moves the task to Human Review; it does not verify any code.
Restart interrupts active runs and clears approvals, never resumes them.

## Shared CLI

Export the same `SYMPHONY_DEMO_TOKEN` and set
`SYMPHONY_URL=http://127.0.0.1:4001`. Get revisions before mutations:

```sh
python3 cli/symphonyctl tasks board --json
python3 cli/symphonyctl tasks create --title 'Review timeout' --project demo --revision 1
python3 cli/symphonyctl tasks show TASK_ID --json
python3 cli/symphonyctl tasks move TASK_ID --stage Todo --revision 1
python3 cli/symphonyctl tasks plan TASK_ID --text 'Inspect timeout' --revision 2
python3 cli/symphonyctl tasks comment TASK_ID --text 'Ready for review' --revision 3
python3 cli/symphonyctl tasks link TASK_ID --kind pull_request --title 'Related PR' --url https://github.com/example/project/pull/1 --revision 4
```

Creation uses `board_revision`; other writes use the task revision. Examples
assume no concurrent writes. Supply an explicit `--key` when you need retryable
receipt recovery. Imports use `tasks import-agent --file`, `tasks import-pr
--url`, or `tasks import-runtime --source-url --issue`; see CLI help and tests.
Imports are operator supplied observations, not independently verified outcomes.
No provider is contacted unless you invoke its import or enable discovery.

## Optional GitLab discovery

Use a **fresh database** and configure the process through your secret manager:

```sh
export SYMPHONY_GO_MODE=gitlab_discovery
export SYMPHONY_GITLAB_ENDPOINT=https://gitlab.example/api/v4
export SYMPHONY_GITLAB_PROJECT=group/project
export SYMPHONY_DEMO_DB=/path/to/dedicated/gitlab-board.sqlite
# Supply SYMPHONY_GITLAB_TOKEN securely; never put it in a URL or commit it.
./bench/go-manual
```

Use a project-scoped read-only token with access to its issues (GitLab `read_api`
where available). The adapter only issues GET for the configured issue list,
never follows redirects and never mutates GitLab. It polls immediately, then
once every 30 seconds. There may initially be no cards. Failures appear as
`runtime_error`; the last good data remains. Source changes increment revisions
without replacing local documents/comments. A source transition to closed sets Done; reopening sets Todo. These transitions
override local stages. Other source changes preserve local stage edits, which can
therefore intentionally differ from GitLab status. Local moves never write back
to GitLab, and `release_verified` remains false. Missing issues in a bounded
response are retained. Endpoint URLs must not contain query/fragment delimiters,
including a trailing `?` or `#`.

Imported issue execution is **unavailable** in Go. Manual stage/plan/comment/link
changes stay local. Changing endpoint/project/credential requires a fresh DB.
See [discovery limits and execution architecture](GO_GITLAB_DISCOVERY.md).

## Reproduce validation

```sh
cd go-manual
go test -race -cover ./...
go vet ./...
cd ..
python3 -m unittest discover -s cli -p 'test_*.py'
python3 scripts/test_symphonyctl.py
# Build bench/go-manual first; this launches a fresh isolated fixture process:
python3 bench/board-contract.py
# With a fresh running fixture, Node, Playwright and local Chromium:
node bench/ui-board-check.cjs
```

The browser test uses synthetic cards and records desktop/mobile screenshots in
`docs/go-evidence/board/`. Provider tests use local TLS servers and synthetic
credentials. They do not establish live GitLab/Codex interoperability. The old
resource benchmark is fixture-only and was not rerun as a runtime comparison.
