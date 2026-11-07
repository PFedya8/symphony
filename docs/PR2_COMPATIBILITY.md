# PR #2 / PR #3 coordination

Reviewed PR #2 CLI commit `1765cc8814244c55c54c9974ec54a2048776410f` and approval
head `7dd3abc83bdfaf0f129a7b266626389a5fb7192a` against PR #3.

## Shared CLI resolution

The reusable CLI reconciliation is commit `3fd60dccb74c82449b3d8bc825cc6096cf9a778f`.
Use that version of `cli/symphonyctl` when resolving the two PRs. It retains PR #2's
arbitrary opaque-ID support and its six tests, plus PR #3's generated-ID/approval
coverage. A single public-argparse normalization replaces the older format-specific
private parser override.

The original PR #2 six-test suite passed on Python 3.12/3.13 but produced ten error
subcases on Python 3.11. The reconciled parser puts known options before all literal
positionals and binds option values with `=`. Both suites (7 + 6 tests) pass on
Python 3.11, 3.12 and 3.13, including these independently reported cases:

```sh
symphonyctl --json runs stop -run --revision 2
symphonyctl runs retry -run --revision 2 --approval -preview
```

Opaque IDs and persisted data are not changed. Full option names are required.
A first otherwise-unrecognized token in the ID position is an ID (the unavoidable
ambiguity required by PR #2's direct opaque-ID syntax); unknown extra options after
an ID still reject. IDs equal to known option names require an explicit `--` boundary.

## Go approval alignment

Go now mirrors PR #2's service read policy:

- Shared snapshot runs omit `approval`; preview audit results omit the private `id`;
  other event results omit `approval`. The events endpoint uses the same redaction.
- `approval_valid` reports only whether the caller's supplied approval is still
  current, revision-matched and unexpired; ordinary snapshots without one return false.
- Go's browser keeps its own approval locally and probes through authenticated POST
  `commands` with `{op: "snapshot", approval: <owned id>}`. No approval is put in a URL.
  This read request works through PR #2's existing command controller as well.
- The browser clears replaced, expired, consumed and revision-invalid approvals on
  refresh. It does not copy approvals from another tab's history. Polls avoid replacing
  unchanged controls, and a late response cannot clear a newer locally created preview.
- Redaction applies to public copies only. Durable private command responses and
  exact idempotency replay remain intact; replay does not reinstate replaced approvals.

This is a fixture capability boundary, not per-user account authorization. All clients
still use the configured demo token. PR #2 remains the owner of the Elixir approval/
LiveView changes; this PR does not transplant its deployment, guide or Elixir UI work.
Standalone PR #3's Elixir baseline gets the approval policy only when PR #2 is integrated.

## Merge check and validation

A temporary local merge of PR #2 and PR #3 required explicit resolutions in
`README.md`, `elixir/README.md`, `elixir/WORKFLOW.md`, and `cli/symphonyctl`.
Keep both documentation additions and use the reconciled CLI above. Elixir's capacity
safety changes and PR #2's approval redaction/validity changes merged together.
No merge was published and neither PR was merged into main.

The combined Elixir code, PR #2 tests, PR #3 capacity tests and reconciled CLI passed
`make all` with cached dependencies (`HEX_OFFLINE=1`): **313 tests, zero failures,
six skipped**, configured coverage 100%, lint/specs and Dialyzer passed.

Go's race suite passed at **90.8% statement coverage**, including replacement,
expiry, revision changes, consumption, snapshot/events confidentiality, HTTP private
validity probing, and preservation of private idempotent replay. Vet/build passed.
Both CLI suites are now run by the Go CI job.

Real Chromium tests passed for two-tab preview replacement, hold invalidation,
run completion and public redaction; the original start/stop/hold/retry/mobile flow
also passed. Screenshots 01–04 were refreshed; 05–06 show the approval behavior.
`bench/ui-approval-check.cjs` reproduces the two-tab test against a fresh Go database.
The resource benchmark was not rerun after these correctness changes.
