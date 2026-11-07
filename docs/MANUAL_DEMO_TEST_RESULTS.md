# Manual demo verification — 2026-11-06 UTC

Baseline: `291937e7c26d7c5c89894238ae23cb18b4fe4653` on
`feat/devops-manual-slice`. Changes are isolated on `test/manual-demo-preview`.

Runtime: Elixir 1.19.5, Erlang/OTP 28.5.0.6, official Docker image
`elixir:1.19.5-otp-28`, digest
`sha256:d170fadffd75b36146ff40b6e8d5cc881c59d136ae5a2c34a1b394ec33b6cffa`.
The container received the session proxy and a read-only CA bundle for dependency
installation. No production tokens, tracker credentials or repositories were
provided to the simulated worker. Browser automation used system Chromium via
Playwright and a temporary loopback-only relay into the container.

| Check | Observed result |
| --- | --- |
| Targeted demo, GitLab adapter and redirect tests | 22 passed, 0 failures |
| Full ExUnit suite | 311 tests, 0 failures, 6 opt-in live tests skipped |
| Measured coverage | 100%, using existing repository exclusions |
| Full `make all` gate | Passed (exit 0), including Dialyzer with zero errors |
| Format, specs and strict Credo | Passed; no lint issues |
| Real HTTP/CLI and restart smoke | Passed independently and concurrently on ports 4000 and 4001 |
| Invalid ports `80`, `65536`, `abc`, `4001extra` | Rejected before server startup |
| Mobile Chromium, 390 × 844 | Connected LiveView, start, stop/hold, release/preview/retry, simulated success |
| Browser JavaScript runtime errors | None observed |
| Python and JavaScript syntax, whitespace diff | Passed |

The smoke checks created separate temporary databases and random tokens. They
verified authentication rejection, authenticated HTML, approved execution,
persistent idempotent duplicate handling, identical CLI run IDs, completion,
and exact state after process restart. They cleaned up their own processes and
databases. The browser sequence used a separate disposable database and generated
[three screenshots](MANUAL_DEMO_GUIDE.md#browser-evidence-390--844).

## Findings and limits

- Follow-up review fixed stale preview controls: revision changes and expiry clear
  them. History/evidence JSON is now collapsed behind expandable summaries.
- CLI replay guidance now explicitly uses `--key`; process-level checks verify
  two calls with one explicit key create one event, while default keys create two.
- Hex reported security advisories in existing locked dependencies. This PR does
  not update them or claim remote security readiness.
- No phone-accessible live URL was produced. The environment has no configured
  VPN or supported authenticated preview ingress. The app remains loopback-only;
  browser origin checking in the existing endpoint is disabled. No public tunnel,
  authentication bypass or production deployment was made.
- Google Calendar/Google Tasks integrations are absent. GitLab checks used mocked
  responses, not a real account. No credentials or scopes were provisioned.
- The second instance proves port/database/token isolation for the same synthetic
  fixture, not real multi-project tenancy or tracker dispatch.
- Arbitrary execution, production deployments, external integration writes,
  full two-minute wall-clock expiry timing, resource/load benchmarks and macOS packaging are not
  verified here. The separate Go task owns comparative resource benchmarking.

## Independent-review follow-up

The CLI help/source confirms that omitted `--key` uses a new UUID per invocation.
The corrected guide keeps an explicit key and all original arguments for an
uncertain-response replay, and distinguishes that from an intentional new retry.
The real CLI smoke check asserts one sync audit event for two identical explicit-key
calls and two events when the key is omitted. Counting only sync events avoids
races with independent worker lifecycle events.

LiveView checks now assert that start consumes its approval, stop/hold offers no
stale retry, another client's revision change clears approval, and an expired
approval is cleared by the refresh handler. A successful UI retry also verifies
rendered simulation evidence. The expiry timer uses that same refresh handler;
the suite does not spend two minutes testing wall-clock expiry end to end.

Mobile screenshots were recaptured after the fix. Browser automation also opens
and closes an event disclosure and checks that stale retry controls are absent.
The smoke probe now tolerates TIME_WAIT after cleanup while still rejecting an
active listener; a repeat run and active-listener refusal were verified.

## Cross-client preview regression

A two-LiveView test reproduced replacement at the same task revision: client A
retained its start button after B requested a new preview. The service now checks
A's own capability during snapshot refresh and returns only `approval_valid`.
Snapshots and event pages remove preview IDs and run approval credentials from
shared history, including previously persisted records. PubSub still broadcasts
only `:demo_updated`; it never distributes a capability.

The regression asserts A loses the control, B retains a usable approval, A's old
approval is rejected, and neither client's capability appears in shared snapshots,
event pages or the other client's rendered page. The test uses two independently
mounted LiveView processes, not a manually fabricated socket.

A randomized test run also generated an ID beginning with `--`. The shared CLI
now normalizes opaque leading-hyphen positional IDs before argparse, preserving
their exact value and existing options. Six transport-free regression tests cover
single/double hyphens, options before/after IDs, explicit separators, retry/read
commands, normal flags, missing revision and unknown extra options. Run them with
`python3 scripts/test_symphonyctl.py`. The real HTTP parity test retains its original
ID-before-options command syntax.
