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
| Full ExUnit suite | 310 tests, 0 failures, 6 opt-in live tests skipped |
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

- The UI can retain a stale preview after a revision change; the service rejects
  stale approval use. Obtain a new preview after releasing hold.
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
  expired-approval timing, resource/load benchmarks and macOS packaging are not
  verified here. The separate Go task owns comparative resource benchmarking.
