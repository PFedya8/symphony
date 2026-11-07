# Go / Elixir board compatibility

Inspected contract and implementation: PR #4, `feat/manual-task-board`,
`fb96c957d5ecb088522deb82de52c012d17cf9c8`. `cli/symphonyctl` and
`scripts/test_symphonyctl.py` are copied unchanged from that head. Both use the
existing `/api/v1/control/{snapshot,commands,capabilities,events}` endpoints;
`/tasks` is the browser entry. The prose contract mentions `/api/v1/tasks`, but
that is not a route in the inspected Elixir router; Go matches actual routes.

| Capability | Go behavior |
| --- | --- |
| Board and task details | Nine canonical stages, up to 100 tasks, project/search filters, revisions |
| Shared mutations | create, move, plan, check, link, worklog, comment, evidence |
| Imports | Shared CLI GitHub PR, reviewed agent JSON, local runtime snapshot; receipt recovery before source read |
| Approval/run controls | Task-bound private preview, start/retry, stop/hold; one simulated worker globally, three attempts per task |
| GitLab source | Opt-in HTTPS read-only polling of latest 100 issues, source updates, explicit errors |
| Real runtime execution | **Unsupported.** Imported tasks reject preview/start/retry; public runtime-start rejected |
| Runtime mode | `fixture` or `gitlab_discovery`; never advertises `gitlab_runtime` |
| Provenance | Operator-authored plans/comments and unverified links/reports; simulated evidence explicitly labeled |
| Isolation | Separate instance/DB/token/port per real project; project labels/filters are not permissions |

The Go approval token is never published in snapshots/events. Exact command
receipts survive restart; active fixture runs become interrupted and approvals
are cleared. Schema 1 fixture data migrates to Go schema 2 without changing its
identity. Never share Go and Elixir SQLite files. Discovery scope hashes endpoint,
project and credential; changing any requires a fresh dedicated database.

The board deliberately retains PR #3's safety improvement: after 1,000 command
receipts, effective holds and stop remain durable and replayable. The multi-task
bound is up to 100 holds plus one global active-run stop. No new tasks, starts,
releases or ordinary writes are accepted at capacity. The inspected PR #4 guard
rejects all writes at the cap. Events retain the latest 1,000 entries; receipts
are never evicted. Go's single-task benchmark previously had a two-record bound.

CLI abbreviations remain supported when unambiguous. Board `--kind` makes the
old `--k` ambiguous; use `--key` (or currently `--ke`). `--j`, `--rev` and opaque
hyphen-prefixed identifiers remain tested. Prefer full flags in scripts.

Go starts with one fixture, while Elixir seeds six. Create extra tasks through
UI/CLI; the screenshot test does so through actual durable API calls. Fixture
completion moves its task to Human Review and never sets `release_verified`.
Walkthrough embeds require an explicit click and allowlisted Vimeo/YouTube URLs.

No live GitLab/Codex integration was tested. No full orchestrator parity is
claimed. The unchanged `bench/comparison.json` describes the old single-task
fixture baseline pinned in `bench/GO_COMPARISON.md`, not this board or GitLab
runtime performance. No comparison of real worker resource use is available.

## Integration check

A temporary `git merge-tree` against PR #4 `fb96c957` found conflicts in
`.gitignore`, `README.md`, `SPEC.md`, `elixir/README.md`, `elixir/WORKFLOW.md` and
`elixir/lib/symphony_elixir/demo.ex`. The shared CLI merged without conflict.
The Elixir service conflict combines the board's task-scoping changes with this
branch's earlier stop/hold-at-capacity fix: retain the new board semantics and
adapt the safety exception to task-scoped checks and the 100-task bound. Do not
resolve it by restoring the old single-task service or dropping the safety fix.
No combined PR #4 Elixir runtime test has been claimed; this remains an explicit
integration/review step. No merge commit or main-branch change was made.

## Source status and local stages

Source status (`source_state`/`status`) comes from GitLab; board stage is a local
workflow label. A source transition to closed sets Done; closed to opened sets
Todo, overriding the previous local stage. Metadata-only source changes and
unchanged polls preserve local stage edits. Thus an operator can intentionally
leave an opened issue in Done or a closed issue in Rework until the next source
status transition. Local moves never reopen or close GitLab issues. Neither
source closure nor local Done verifies a release; `release_verified` stays false.
Each changed source snapshot increments the task revision once, so stale local
drafts conflict; unchanged polling does not increment it.

Endpoint configuration rejects any query or fragment delimiter, including bare
`?` or `#`, before any request. This prevents resource paths from being appended
into a query or discarded as a fragment.
