# Shared Symphony CLI

`symphonyctl` talks to the same HTTP backend as the web controls. Set
`SYMPHONY_URL` and `SYMPHONY_DEMO_TOKEN`; see the Go or Elixir guide for server setup.

IDs are opaque. Pass leading-hyphen IDs unchanged, with options before or after
the command/identifier. Leading-hyphen approval/key values also work:

```sh
python3 cli/symphonyctl --json runs stop -run --revision 2
python3 cli/symphonyctl runs retry --leading-run --revision 3 --approval -preview
python3 cli/symphonyctl runs logs --opaque-run --follow
```

The CLI normalizes the declared options ahead of the positional arguments, then
uses argparse's explicit argument boundary. Option values are bound with `=`
internally. This is compatible with Python 3.11+ and does not depend on a generated
ID length or a private argparse override. No stored IDs or generator format changed.

Known option names remain options. If an ID itself equals a known option name,
use an explicit boundary; for a value equal to an option name, use `=`:

```sh
python3 cli/symphonyctl runs stop --revision 2 -- --json
python3 cli/symphonyctl runs retry -run --revision 3 --approval=--json
```

Unambiguous long-option abbreviations remain supported, matching PR #2 and
argparse: for example `--j`, `--rev`, `--app` and `--k`. Prefer full names in
scripts so future option additions cannot make an abbreviation ambiguous. To support
arbitrary opaque IDs directly, the first otherwise-unrecognized token in the ID
position is treated as the ID, even if it looks like an option. Unknown extra
options after an ID still fail before HTTP; the backend validates actual IDs,
revision, approval and supported operations. Resume remains unsupported.

Run both deterministic suites from the repository root:

```sh
python3 -m unittest discover -s cli -p 'test_*.py'
python3 scripts/test_symphonyctl.py
```

The first suite covers generated and arbitrary IDs, global flags, approval/key
values, reads, mutations, logs-follow, explicit boundaries, extra-option rejection
and a real CLI subprocess against a local HTTP test server. The second retains
PR #2's current ten opaque-ID/global-option/HTTP regressions unchanged. The transport stub does not claim
resume support in the real service. Both suites run in Go CI and were verified
on Python 3.11, 3.12 and 3.13.
