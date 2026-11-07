# Verification evidence

Screenshots were captured from a running Go backend through Chromium 156.0.8078.79
and Playwright 1.62.1, not drawn or mocked:

1. `01-connected.png`: authenticated queue and revision 1.
2. `02-stopped.png`: started simulation stopped, hold enabled.
3. `03-retry-succeeded.png`: hold released, a new approved retry succeeded with
   parent lineage and explicitly simulated evidence.
4. `04-mobile.png`: the same verified state at 390×844 viewport; full-page capture.

`bench/ui-check.cjs` asserts each transition and absence of page errors. It also
checks no horizontal overflow at the phone viewport. It requires a fresh database;
rerunning against a used fixture can legitimately exhaust its attempt budget.

Other checks are recorded in the benchmark report and Go README. Screenshots are
visual evidence of the tested flow, not proof of external-agent execution,
production deployment, Google integrations, every browser, or every failure mode.

Screenshots 01–04 were refreshed after approval redaction. Additional evidence:

5. `05-replaced-preview.png`: first browser tab after the second tab replaced its
   preview; no stale start button and no approval IDs in shared history.
6. `06-redacted-run.png`: completed run with shared snapshot/history redaction.

`bench/ui-approval-check.cjs` asserts both tabs, hold invalidation, private history,
run completion and no page errors. See `docs/PR2_COMPATIBILITY.md` for merge validation.
