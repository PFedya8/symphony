# Resource validation procedure

This fixture slice deliberately permits only one worker and three attempts. Do not
raise production concurrency to satisfy a benchmark. Full handoff benchmarks with
1,000 tasks / 10,000 history rows / four workers remain pending a test-only workload
adapter. No resource target is claimed met.

For a local smoke measurement, record checkout SHA, dirty diff, OS, CPU, runtime,
build profile, process PID and command. Sample `/proc/PID/stat` and
`/proc/PID/status` once per second for 60 seconds before starting a fixture and
while it runs. Report CPU delta divided by wall time and CLK_TCK, RSS and peak RSS.
Keep Python CLI, browser renderer, build tools and BEAM measurements separate.
This short development check is not the five-trial production benchmark.
