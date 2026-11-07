# Leading-hyphen CLI identifier regression

Historical evidence for the initial fix at `748fbbe`. The generalized coordinated
fix is documented in `cli/README.md` and `docs/PR2_COMPATIBILITY.md`; it supersedes
the format-specific parser described below.

Both backends generate IDs by URL-safe encoding 18 random bytes. A valid ID may
begin with `-` or `--`. The original argparse parser mistook those positional IDs
for options; generated approval IDs had the same problem as option values.

Deterministic tests using `-AAAAAAAAAAAAAAAAAAAAAAA` and
`--BBBBBBBBBBBBBBBBBBBBBB` reproduced 14 parser-error subcases before the fix.
The shared CLI now treats the existing 24-character URL-safe ID syntax as values
when classifying optional arguments. It does not regenerate or migrate persisted
IDs, change backend semantics, or suppress ordinary unknown-option errors.

Validation:

- Six regression tests and their operation/ID subcases passed on Python 3.11,
  3.12 and 3.13. Includes actual CLI subprocess requests to a local HTTP stub.
- Shared HTTP/CLI contract passed against the current Go and Elixir implementations.
- Full Elixir suite: 312 tests, zero failures, six skipped.
- CLI suite added to `.github/workflows/go-manual.yml`.

The classifier targets the current generated format, not every possible external
identifier grammar. Arbitrary legacy hyphen-prefixed positional IDs still work with
an explicit `--` boundary and options before the command; arbitrary option values
can use `--approval=VALUE` / `--key=VALUE`. See `cli/README.md`.
