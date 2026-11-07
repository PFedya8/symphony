# Go GitLab discovery boundary

The Go adapter reads issue metadata. It does **not** implement the Elixir
`gitlab_runtime` execution contract. Its mode is `gitlab_discovery`, and imported
tasks explicitly have `execution_supported: false` and `source_dispatchable:
false`. A board card, manual stage, linked MR or report is not evidence that an
agent ran, a check passed or a merge happened. `release_verified` stays false.

The adapter issues one authenticated GET against the configured HTTPS GitLab
API endpoint's `/projects/<encoded-project>/issues` resource. It requests all
states, ordered by latest update, with a maximum of 100 records. It never follows
redirects, provider pagination URLs, arbitrary paths or other projects; it never
writes to GitLab. Requests time out after ten seconds; response bodies are capped
at 2 MiB and malformed/oversized responses fail as a whole. Provider error bodies,
request URLs and credentials are not included in returned errors.

This bounded discovery window is not a complete project export. Previously seen
issues outside the current window must be retained; their absence is not closure.
A project with over 100 issues needs a separately designed reconciliation and
pagination policy before completeness can be claimed. The current adapter also
does not retrieve issue dependencies, comments, MR activity, author identities or
agent observations. Source links are unverified references, not imported evidence.

The credential lives only in the adapter's memory. Its scope hash includes the
endpoint, project and credential, so the service can reject changes against an
existing database without storing the credential. Use a dedicated instance and
database for another project; board filters are not tenant access controls.
No real credentials or live GitLab requests were used during development. Tests
use local TLS servers and synthetic credentials.

## Why execution remains unavailable

At canonical Elixir board revision `fb96c957d5ecb088522deb82de52c012d17cf9c8`,
`RuntimeBoard` is owned by the existing `SymphonyElixir.Orchestrator` process.
That process refreshes source data before approval/dispatch, reserves the run,
fences configuration changes, owns the single worker, observes worker exit and
blocks automatic retries. The Go fixture has only a simulated timer and no
AgentRunner, workspace owner, sandbox policy or scheduler interoperability API.
Starting a shell command from the Go discovery service would introduce a second
execution owner and would bypass those invariants.

A future implementation should either make Go a client of the existing Elixir
board API, leaving all approvals, reservations and worker ownership there, or
port the full orchestration and fencing contract with equivalent tests. Neither
path is implemented here. Do not share the two implementations' SQLite files or
claim runtime resource parity from the fixture benchmark.

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

For a database affected before this fix, an already persisted opened/Done task is
indistinguishable from an intentional local Done label. Move that card to Todo
manually if it should be reopened on the board; the update does not overwrite
all opened/Done tasks. Subsequent source close/reopen transitions reconcile as
specified above.
