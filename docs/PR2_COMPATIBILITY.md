# PR #2 / PR #3 coordination

Reviewed PR #2 through `b1050cb`, including its approval changes from
`7dd3abc83bdfaf0f129a7b266626389a5fb7192a`, against PR #3.

## Current shared CLI resolution

The canonical CLI and `scripts/test_symphonyctl.py` now exactly match PR #2 commit
`b1050cb`. Both branches preserve argparse's unambiguous long-option abbreviations,
including `--j` / `--rev` and inline `--rev=2`. The older PR #3 no-abbreviation
policy and reusable CLI commit `3fd60dc` are superseded; do not restore that policy
when merging. Byte-identical CLI implementations now merge without a CLI conflict.

PR #2's current ten-test suite reproduced one failing abbreviated-flag subcase
against PR #3 head `625546a`. After adopting the shared version, both current suites
(8 + 10 tests) pass on Python 3.11, 3.12 and 3.13. PR #3 additionally tests inline
abbreviations and that a missing approval value does not consume `--rev`.
Generated and arbitrary opaque IDs, global options, leading-hyphen approval/key
values, explicit argument boundaries and existing HTTP behavior remain covered.

Prefer complete option names in scripts because future option additions can make
an abbreviation ambiguous. The first otherwise-unrecognized token in the ID
position remains an opaque ID; unknown extra options after an ID still reject.
IDs equal to known option names require an explicit `--` boundary.

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
`README.md`, `elixir/README.md` and `elixir/WORKFLOW.md`.
Keep both documentation additions. The canonical CLI merges unchanged. Elixir's capacity
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
