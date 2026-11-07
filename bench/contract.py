#!/usr/bin/env python3
"""Black-box API/CLI contract against both backends, each on a fresh database."""
import json, os, pathlib, secrets, subprocess, tempfile, time, urllib.error, urllib.request, uuid

ROOT = pathlib.Path(__file__).resolve().parents[1]


def run(kind):
    with tempfile.TemporaryDirectory() as tmp:
        port = 4001 if kind == "go" else 4000
        env = dict(
            os.environ,
            SYMPHONY_DEMO_TOKEN=secrets.token_hex(32),
            SYMPHONY_DEMO_DB=tmp + "/state.sqlite",
            SYMPHONY_GO_ADDR=f"127.0.0.1:{port}",
            GOMAXPROCS="2",
            ERL_FLAGS="+S 2:2",
        )
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
        with open(tmp + "/log", "w") as log:
            p = subprocess.Popen(
                command, cwd=ROOT / "elixir", env=env, stdout=log, stderr=log
            )

            def api(view, body=None, authorized=True):
                req = urllib.request.Request(
                    f"http://127.0.0.1:{port}/api/v1/control/" + view,
                    data=None if body is None else json.dumps(body).encode(),
                    headers={
                        "Authorization": "Bearer "
                        + (env["SYMPHONY_DEMO_TOKEN"] if authorized else "wrong"),
                        "Content-Type": "application/json",
                    },
                )
                try:
                    with urllib.request.urlopen(req, timeout=5) as r:
                        return r.status, json.load(r)
                except urllib.error.HTTPError as e:
                    raw = e.read()
                    try:
                        return e.code, json.loads(raw)
                    except ValueError:
                        return e.code, raw.decode()

            def cmd(op, expected=None, **extra):
                req = dict(
                    op=op,
                    revision=api("snapshot")[1]["task"]["revision"],
                    key=str(uuid.uuid4()),
                    **extra,
                )
                status, body = api("commands", req)
                if expected:
                    assert status == 409 and body["error"]["code"] == expected, (
                        kind,
                        op,
                        status,
                        body,
                    )
                else:
                    assert status == 200, (kind, op, status, body)
                return body

            try:
                for _ in range(300):
                    try:
                        if api("capabilities")[0] == 200:
                            break
                    except OSError:
                        pass
                    if p.poll() is not None:
                        raise RuntimeError(pathlib.Path(tmp + "/log").read_text())
                    time.sleep(0.05)
                else:
                    raise RuntimeError("readiness timeout")
                assert api("snapshot", authorized=False)[0] == 401
                assert api("capabilities")[1] == dict(
                    simulated=True,
                    manual=True,
                    resume=False,
                    max_agents=1,
                    max_attempts=3,
                )
                cmd("resume", "resume_not_supported")
                cmd("start", "approval_required")
                req = dict(op="hold", revision=1, key="repeat")
                first = api("commands", req)
                assert first[0] == 200
                assert api("commands", req) == first
                assert (
                    api("commands", dict(req, op="sync"))[1]["error"]["code"]
                    == "idempotency_conflict"
                )
                assert (
                    api("commands", dict(req, key="stale"))[1]["error"]["code"]
                    == "stale_revision"
                )
                cmd("preview", "held")
                cmd("release-hold")
                a = cmd("preview")
                r = cmd("start", approval=a["id"])
                cmd("preview", "capacity")
                cmd("stop", run_id=r["id"])
                for _ in range(100):
                    if api("snapshot")[1]["runs"][0]["state"] == "stopped":
                        break
                    time.sleep(0.02)
                else:
                    raise AssertionError("stop did not settle")
                cmd("preview", "held")
                cmd("release-hold")
                a = cmd("preview")
                r2 = cmd("retry", approval=a["id"], run_id=r["id"])
                for _ in range(200):
                    snapshot = api("snapshot")[1]
                    if snapshot["runs"][-1]["state"] == "succeeded":
                        break
                    time.sleep(0.02)
                else:
                    raise AssertionError("retry did not finish")
                assert snapshot["runs"][-1]["parent_id"] == r["id"]
                assert snapshot["runs"][-1]["evidence"]["simulated"] is True
                assert snapshot["task"]["release_verified"] is False
                page = api("events?cursor=0")[1]
                assert len(page["items"]) >= 10
                cli = subprocess.run(
                    [
                        "python3",
                        str(ROOT / "cli/symphonyctl"),
                        "runs",
                        "list",
                        "--json",
                    ],
                    env=dict(env, SYMPHONY_URL=f"http://127.0.0.1:{port}"),
                    stdout=subprocess.PIPE,
                    check=True,
                )
                assert len(json.loads(cli.stdout)) == 2
                print(
                    f"{kind}: PASS shared HTTP/CLI contract (auth, capabilities, approval, hold, idempotency, stale revision, capacity, stop, retry lineage, evidence, events)",
                    flush=True,
                )
            finally:
                p.terminate()
                try:
                    p.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    p.kill()
                    p.wait()


for kind in ("go", "elixir"):
    run(kind)
