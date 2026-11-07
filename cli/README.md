# Shared Symphony CLI

`symphonyctl` talks to the same HTTP backend as the web controls. Set
`SYMPHONY_URL` and `SYMPHONY_DEMO_TOKEN`; see the Go or Elixir guide for server setup.

Both fixture backends generate 24-character unpadded URL-safe identifiers. These
can start with one or more hyphens. Pass them unchanged, including before flags:

```sh
python3 cli/symphonyctl runs stop '-AAAAAAAAAAAAAAAAAAAAAAA' --revision 2
python3 cli/symphonyctl runs logs '--BBBBBBBBBBBBBBBBBBBBBB' --follow
python3 cli/symphonyctl runs retry '-AAAAAAAAAAAAAAAAAAAAAAA' --revision 3 \
  --approval '-CCCCCCCCCCCCCCCCCCCCCCC'
```

The parser recognizes that generated identifier syntax as a value, not an option.
This also applies to generated approval IDs and idempotency keys. No stored IDs
or generator format changed. Normal option validation remains in place.

For an arbitrary legacy identifier outside that format, use the normal explicit
argument boundary, with options **before** the command (compatible with Python 3.11):

```sh
python3 cli/symphonyctl --revision 2 runs stop -- '-legacy-id'
```

For arbitrary option values beginning with a hyphen, use `--approval=VALUE` or
`--key=VALUE`. These examples illustrate syntax; the backend still validates
revision, identity, approval and supported operations. Resume remains unsupported.

Run deterministic regressions from the repository root:

```sh
python3 -m unittest discover -s cli -p 'test_*.py'
```

Tests cover single/double-hyphen IDs for stop/retry/resume request parsing and
list/show/history/logs, logs-follow, approval/key values, existing normal IDs,
explicit argument boundaries, unknown-option rejection, and a real CLI subprocess
against a local HTTP test server. The transport stub does not claim that resume
is supported by the real service. The Go CI workflow runs this suite for both
implementations' shared client. Verified locally on Python 3.11, 3.12 and 3.13.
