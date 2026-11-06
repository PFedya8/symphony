#!/usr/bin/env python3
"""Short development-only coordinator/CLI measurement; not the production benchmark."""
import json
import os
import pathlib
import secrets
import subprocess
import tempfile
import time
import urllib.request

root = pathlib.Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory() as directory:
    env = dict(os.environ, SYMPHONY_DEMO_TOKEN=secrets.token_hex(32),
               SYMPHONY_DEMO_DB=directory + '/demo.sqlite')
    with open(directory + '/server.log', 'w') as log:
        process = subprocess.Popen(['mix', 'run', '--no-start', 'demo.exs'],
                                   cwd=root / 'elixir', env=env, stdout=log, stderr=log)
        try:
            def api(view, body=None):
                req = urllib.request.Request('http://127.0.0.1:4000/api/v1/control/' + view,
                    data=None if body is None else json.dumps(body).encode(),
                    headers={'Authorization': 'Bearer ' + env['SYMPHONY_DEMO_TOKEN'],
                             'Content-Type': 'application/json'})
                with urllib.request.urlopen(req, timeout=2) as response:
                    return json.load(response)
            started = time.monotonic()
            for _ in range(100):
                try:
                    api('capabilities')
                    break
                except OSError:
                    if process.poll() is not None:
                        raise RuntimeError('backend exited; see log')
                    time.sleep(.1)
            else:
                raise RuntimeError('backend readiness timeout')
            startup = time.monotonic() - started
            def sample(seconds):
                def ticks():
                    values = pathlib.Path(f'/proc/{process.pid}/stat').read_text().split()
                    return int(values[13]) + int(values[14])
                before = ticks()
                start = time.monotonic()
                time.sleep(seconds)
                elapsed = time.monotonic() - start
                status = pathlib.Path(f'/proc/{process.pid}/status').read_text().splitlines()
                rss = next(int(line.split()[1]) for line in status if line.startswith('VmRSS:'))
                return {'seconds': elapsed, 'cpu_core_fraction': (ticks()-before)/os.sysconf('SC_CLK_TCK')/elapsed,
                        'rss_kib': rss}
            idle = sample(10)
            preview = api('commands', {'op':'preview', 'revision':1, 'key':'preview'})
            run = api('commands', {'op':'start', 'revision':1, 'key':'start', 'approval':preview['id']})
            active = sample(2)
            begin = time.monotonic()
            subprocess.run([str(root/'cli/symphonyctl'), 'runs', 'list', '--json'],
                           env=env, check=True, stdout=subprocess.DEVNULL)
            cli_latency = time.monotonic()-begin
            print(json.dumps({'profile':'development, one trial, one fixture; no browser',
                'startup_seconds':startup, 'idle':idle, 'one_simulated_worker':active,
                'single_cli_seconds':cli_latency, 'run_id':run['id']}, indent=2))
        finally:
            process.terminate()
            process.wait(timeout=10)
