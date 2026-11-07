> Historical single-task fixture measurements. The Go board/discovery extension
> has not been benchmarked against Elixir's real runtime. Do not apply these
> resource figures to multi-task boards, GitLab polling or actual agent work.

# Go versus Elixir manual fixture benchmark

## Scope and equivalence

Baseline is main `c1aa579de8bf726a31cbabbaddfe1cb4fd52e4b0`, which includes the
published manual slice `291937e7c26d7c5c89894238ae23cb18b4fe4653`. Go is a separate
implementation of that slice, sharing the existing CLI HTTP protocol. Both have
one fixture, one active simulated worker, three attempts, two-minute approvals,
revision checks, idempotency, holds, explicit retries, SQLite FULL/exclusive
snapshot persistence, audit history and interrupted-run recovery.

This does **not** compare full Symphony implementations. Elixir loads the larger
OTP/Phoenix application, tracker infrastructure and observability modules; Go
loads a small fixture-specific HTTP server. Go has a polling HTML UI instead of
LiveView, no real tracker/agent integration, no push updates, and no token/session
compatibility with Phoenix. The fixture worker is a sleeping OTP task or Go timer,
not a CPU-intensive Codex subprocess. Neither result predicts real agent costs.

## Reproduce

Run on Linux with Python 3, Go 1.25.4, C compiler, Elixir 1.19.4 and OTP 28.3:

```sh
(cd go-manual && go build -o ../bench/go-manual .)
(cd elixir && mix deps.get && mix compile)
python3 bench/compare.py --trials 3 --idle 5 --output bench/comparison.json
```

The Elixir baseline starts through `elixir -pa '_build/dev/lib/*/ebin' ../bench/elixir-launch.exs`,
not `mix run`, avoiding compilation or Mix startup overhead in measurements.
The launcher loads the same development config as Mix before calling `demo.exs`.
Go runs its compiled binary. Neither is a production release build.
SQLite versions were queried at runtime: Go 3.50.4 (go-sqlite3 v1.14.32),
Elixir 3.54.1 (Exqlite from the baseline lockfile). Storage settings match,
but SQLite/library versions differ; this is an application comparison, not a
controlled language-only experiment. Run no other
builds/tests during measurement. The script requires free local ports 4000/4001.
It creates separate temporary databases, starts only one server at a time,
alternates Go/Elixir order, stops each child, and removes temporary fixture data.

An optional container recipe pins both toolchain versions:

```sh
docker build -f bench/compare.Dockerfile \
  --secret id=proxy_ca,src=/etc/ssl/certs/ca-certificates.crt \
  -t symphony-fixture-comparison .
mkdir -p /tmp/symphony-benchmark-output
docker run --rm \
  -v /tmp/symphony-benchmark-output:/results \
  symphony-fixture-comparison --output /results/comparison.json
```

The CA bundle must include any required proxy CA. Preserve configured HTTP proxy
settings. The reported run used the same pinned Elixir container with mounted
source and a Go 1.25.4 binary built on the same host; the optional image recipe is
a reproducibility convenience, not the exact image used for those results.

## Method and resource boundaries

Each fresh-instance trial measures startup to authenticated HTTP readiness,
five seconds idle, two seconds of snapshot polling during the three-second
simulation, three seconds of snapshot polling after completion, three seconds of
persisted `sync` commands, then one CLI invocation. Polling is paced by 50ms sleeps
plus request/sample overhead, not maximum throughput. Each sync operation includes
a revision GET and a command POST. All samples use the same host and filesystem.

- **Coordinator/server UI:** `/proc` CPU deltas and sampled RSS are summed over the
  server process tree. HTTP handling is inside the same process as the coordinator;
  UI-polling and idle phases show combined costs, not separately attributable heaps.
- **External agent:** zero processes and zero separately measured resources. The
  simulated worker is inside the coordinator; its incremental cost includes polling.
- **CLI:** separate child CPU, sampled peak RSS and wall time; one short invocation
  per trial. Sampling can miss peaks.
- **Browser UI:** not included in numeric CPU/RAM comparison. Real Chromium UI flow
  and mobile layout were tested separately with screenshots, but browser resources
  and Phoenix websocket rendering costs were not measured.
- **Load generator, container daemon and compiler:** excluded from process-tree totals.
  Builds/tests completed before samples. Shared-host noise is still possible.

Both runtimes use two scheduler/parallelism slots (`ERL_FLAGS='+S 2:2'`,
`GOMAXPROCS=2`). This is not a CPU affinity/cgroup cap. RSS is resident memory,
not proportional/private memory; summing process RSS can double-count shared pages.
CPU is percent of one core (100% = one core); 10ms accounting resolution can show
zero for short idle samples. Three trials and synthetic low load do not establish
statistical significance, sustained capacity, power use, or a general language ranking.

## Measurements

See `comparison.json` for raw per-trial results and host metadata. The completed run is summarized below.

Host: INTEL(R) XEON(R) PLATINUM 8573C; 5 visible logical CPUs; Linux container.

Values below are medians across three trials; RSS is the median of each phase’s samples.

| Phase | Go RSS MiB | Elixir RSS MiB | Go CPU % of one core | Elixir CPU % of one core |
|---|---:|---:|---:|---:|
| idle | 8.53 | 90.63 | 0.00 | 0.60 |
| simulated active with polling | 9.43 | 90.22 | 1.49 | 2.96 |
| ui api polling | 11.41 | 90.60 | 1.65 | 2.65 |
| durable sync writes | 13.74 | 90.93 | 5.66 | 6.58 |

| Metric | Go | Elixir |
|---|---:|---:|
| Startup to readiness (s) | 0.052 | 0.905 |
| CLI wall time (ms) | 68.165 | 69.988 |
| CLI CPU (ms) | 64.977 | 68.263 |
| CLI sampled peak RSS (MiB) | 19.387 | 19.336 |
| UI API polling median latency (ms) | 0.937 | 1.422 |
| Sync operation median latency (ms) | 4.814 | 4.644 |

Go idle RSS ranged 8.49–8.68 MiB; Elixir ranged 88.88–92.85 MiB.
Go polling CPU ranged 1.33–3.29% of one core; Elixir 2.33–2.66%.
Durable-write phases completed 53–55 Go and 55 Elixir operations per trial.
Startup probing has 50ms resolution; Go startup values are near that floor.

The smaller Go fixture has substantially lower resident memory in this setup.
CPU differences are small and overlap in polling; write latency is comparable.
This is evidence about these two fixture applications under this paced workload,
not a claim that Go is universally faster or that the full Elixir system should
be replaced. No hardware power/energy measurement was taken.

## Verification

Go race tests: 11 top-level tests passed, 82.3% statement coverage; vet and formatting passed.
Elixir `make all`: passed, 310 tests, zero failures, six skipped; configured coverage
100%, specs/Credo/Dialyzer passed. `python3 bench/contract.py` passed against both
implementations. Chromium UI checks passed; screenshots and detailed test evidence
are in [`docs/go-evidence`](../docs/go-evidence/README.md).

The optional Docker recipe was also built successfully and smoke-tested with one
trial per implementation and one-second idle windows. Those packaging smoke
numbers are deliberately not mixed into the three-trial results above.

A later [capacity-safety follow-up](../docs/go-evidence/CAPACITY_FIX.md) fixes
stop/hold at the history limit in both backends and adds Go CI. Its validation
passed 13 Go tests (82.9% coverage) and all Elixir gates (312 tests, six skipped).
The measurements above predate that targeted fix and were not rerun; their
low-volume workload never reaches the changed capacity branch.
