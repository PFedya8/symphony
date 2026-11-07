#!/usr/bin/env python3
"""Same-host sequential fixture benchmark. Run inside the prepared Elixir container.
No external agents or browser are launched. UI HTTP polling is measured separately.
"""
import argparse, json, os, pathlib, platform, resource, secrets, statistics, subprocess, tempfile, time, urllib.request, uuid

ROOT = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument("--trials", type=int, default=3)
parser.add_argument("--idle", type=float, default=5)
parser.add_argument("--output", default=str(ROOT / "bench/comparison.json"))
args = parser.parse_args()


def usage(pid):
    # Include descendants (e.g. BEAM port helpers) without counting the load generator.
    parents = {}
    stats = {}
    for p in pathlib.Path("/proc").iterdir():
        if not p.name.isdigit():
            continue
        try:
            fields = (p / "stat").read_text().rsplit(")", 1)[1].split()
            parents[int(p.name)] = int(fields[1])
            stats[int(p.name)] = (
                int(fields[11]) + int(fields[12]),
                int(fields[21]) * os.sysconf("SC_PAGE_SIZE") / 1024,
            )
        except (OSError, ValueError, IndexError):
            pass
    ids = {pid}
    while True:
        expanded = ids | {p for p, parent in parents.items() if parent in ids}
        if expanded == ids:
            break
        ids = expanded
    return {
        "cpu_seconds": sum(stats.get(p, (0, 0))[0] for p in ids)
        / os.sysconf("SC_CLK_TCK"),
        "rss_kib": sum(stats.get(p, (0, 0))[1] for p in ids),
        "process_count": len(ids),
    }


def trial(kind, index):
    with tempfile.TemporaryDirectory() as tmp:
        env = dict(
            os.environ,
            SYMPHONY_DEMO_TOKEN=secrets.token_hex(32),
            SYMPHONY_DEMO_DB=tmp + "/state.sqlite",
            SYMPHONY_GO_ADDR="127.0.0.1:4001",
            GOMAXPROCS="2",
            ERL_FLAGS="+S 2:2",
        )
        port = 4001 if kind == "go" else 4000
        command = (
            [str(ROOT / "bench/go-manual")]
            if kind == "go"
            else [
                "elixir",
                "-pa",
                "_build/dev/lib/*/ebin",
                str(ROOT / "bench/elixir-launch.exs"),
            ]
        )
        with open(tmp + "/server.log", "w") as log:
            p = subprocess.Popen(
                command, cwd=ROOT / "elixir", env=env, stdout=log, stderr=log
            )

            def api(view, body=None):
                req = urllib.request.Request(
                    f"http://127.0.0.1:{port}/api/v1/control/" + view,
                    data=None if body is None else json.dumps(body).encode(),
                    headers={
                        "Authorization": "Bearer " + env["SYMPHONY_DEMO_TOKEN"],
                        "Content-Type": "application/json",
                    },
                )
                with urllib.request.urlopen(req, timeout=5) as r:
                    return json.load(r)

            def mutation(op, **extra):
                return api(
                    "commands",
                    dict(
                        op=op,
                        revision=api("snapshot")["task"]["revision"],
                        key=str(uuid.uuid4()),
                        **extra,
                    ),
                )

            def sample(seconds, load=None):
                before = usage(p.pid)
                start = time.monotonic()
                rss = []
                latencies = []
                count = 0
                while time.monotonic() - start < seconds:
                    if load:
                        began = time.monotonic()
                        load()
                        latencies.append(time.monotonic() - began)
                        count += 1
                    rss.append(usage(p.pid)["rss_kib"])
                    time.sleep(0.05 if load else 0.1)
                elapsed = time.monotonic() - start
                after = usage(p.pid)
                cpu = max(0, after["cpu_seconds"] - before["cpu_seconds"])
                return dict(
                    seconds=elapsed,
                    cpu_seconds=cpu,
                    cpu_one_core_percent=100 * cpu / elapsed,
                    rss_kib_median=statistics.median(rss),
                    rss_kib_peak=max(rss),
                    operations=count,
                    latency_ms_median=(
                        statistics.median(latencies) * 1000 if latencies else None
                    ),
                    process_count=after["process_count"],
                )

            try:
                start = time.monotonic()
                for _ in range(300):
                    try:
                        api("capabilities")
                        break
                    except OSError:
                        if p.poll() is not None:
                            raise RuntimeError(
                                pathlib.Path(tmp + "/server.log").read_text()
                            )
                        time.sleep(0.05)
                else:
                    raise RuntimeError("readiness timeout")
                startup = time.monotonic() - start
                idle = sample(args.idle)
                preview = mutation("preview")
                run = mutation("start", approval=preview["id"])
                active = sample(2, lambda: api("snapshot"))
                while api("snapshot")["runs"][-1]["state"] not in (
                    "succeeded",
                    "failed",
                ):
                    time.sleep(0.05)
                ui = sample(3, lambda: api("snapshot"))
                writes = sample(3, lambda: mutation("sync"))
                before = resource.getrusage(resource.RUSAGE_CHILDREN)
                start = time.monotonic()
                cli = subprocess.Popen(
                    [
                        "python3",
                        str(ROOT / "cli/symphonyctl"),
                        "runs",
                        "list",
                        "--json",
                    ],
                    env=dict(env, SYMPHONY_URL=f"http://127.0.0.1:{port}"),
                    stdout=subprocess.PIPE,
                )
                cli_rss = []
                while cli.poll() is None:
                    cli_rss.append(usage(cli.pid)["rss_kib"])
                    time.sleep(0.001)
                stdout = cli.communicate()[0]
                assert cli.returncode == 0
                cli_wall = time.monotonic() - start
                after = resource.getrusage(resource.RUSAGE_CHILDREN)
                assert json.loads(stdout)[0]["state"] == "succeeded"
                return dict(
                    implementation=kind,
                    trial=index,
                    startup_seconds=startup,
                    idle=idle,
                    simulated_active_with_polling=active,
                    ui_api_polling=ui,
                    durable_sync_writes=writes,
                    cli=dict(
                        wall_seconds=cli_wall,
                        cpu_seconds=after.ru_utime
                        + after.ru_stime
                        - before.ru_utime
                        - before.ru_stime,
                        sampled_peak_rss_kib=max(cli_rss, default=0),
                    ),
                    external_agent=dict(
                        processes=0,
                        cpu_seconds=0,
                        note="No external agent; timer/OTP task is inside coordinator process.",
                    ),
                )
            finally:
                p.terminate()
                try:
                    p.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    p.kill()
                    p.wait()


results = []
for i in range(args.trials):
    for kind in ["go", "elixir"] if i % 2 == 0 else ["elixir", "go"]:
        result = trial(kind, i + 1)
        results.append(result)
        print(json.dumps(result), flush=True)
out = {
    "host": {
        "platform": platform.platform(),
        "logical_cpus": os.cpu_count(),
        "cpu_model": next(
            (
                l.split(":", 1)[1].strip()
                for l in pathlib.Path("/proc/cpuinfo").read_text().splitlines()
                if l.startswith("model name")
            ),
            "unknown",
        ),
    },
    "runtime_limits": {"GOMAXPROCS": 2, "ERL_FLAGS": "+S 2:2"},
    "method": "Sequential alternating order, fresh SQLite per trial, warmed builds; 50ms pacing for synthetic HTTP phases. Process-tree CPU and sampled RSS from /proc. No browser or real agent. CLI CPU from child resource usage; RSS sampled every ~1ms (short-lived peaks may be missed).",
    "results": results,
}
pathlib.Path(args.output).write_text(json.dumps(out, indent=2) + "\n")
