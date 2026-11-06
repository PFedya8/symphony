#!/usr/bin/env python3
"""Real HTTP/CLI/restart checks against a fresh, loopback-only fixture database."""
import base64
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
PORT = int(os.environ.get('SYMPHONY_DEMO_PORT', '4000'))
BASE = f'http://127.0.0.1:{PORT}'


def main():
    # Never send test mutations to an already-running user's demo.
    with socket.socket() as probe:
        probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        probe.bind(('127.0.0.1', PORT))
    with tempfile.TemporaryDirectory(prefix='symphony-check-') as directory:
        token = secrets.token_hex(32)
        env = dict(os.environ, SYMPHONY_DEMO_TOKEN=token,
                   SYMPHONY_DEMO_DB=str(Path(directory) / 'demo.sqlite'), SYMPHONY_URL=BASE)
        basic = 'Basic ' + base64.b64encode(('demo:' + token).encode()).decode()
        bearer = 'Bearer ' + token
        process = None
        with open(Path(directory) / 'server.log', 'w') as log:
            def request(path, body=None, auth=bearer, status=200):
                req = urllib.request.Request(BASE + path,
                    data=None if body is None else json.dumps(body).encode(),
                    headers={'Authorization': auth, 'Content-Type': 'application/json'})
                try:
                    response = urllib.request.urlopen(req, timeout=3)
                except urllib.error.HTTPError as error:
                    response = error
                with response:
                    assert response.status == status, (path, response.status, status)
                    return response.read().decode()

            def api(view, body=None):
                return json.loads(request('/api/v1/control/' + view, body))

            def launch():
                nonlocal process
                process = subprocess.Popen(['mix', 'run', '--no-start', 'demo.exs'],
                    cwd=ROOT / 'elixir', env=env, stdout=log, stderr=log)
                deadline = time.monotonic() + 60
                while time.monotonic() < deadline:
                    if process.poll() is not None:
                        raise RuntimeError('Demo exited during startup; run mix setup first')
                    try:
                        assert api('capabilities')['simulated'] is True
                        return
                    except OSError:
                        time.sleep(.1)
                raise RuntimeError('Demo readiness timeout')

            def stop():
                if process is not None and process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=10)

            try:
                launch()
                request('/tasks', auth='', status=401)
                request('/api/v1/control/snapshot', auth='', status=401)
                request('/api/v1/control/commands', {'op': 'hold'}, auth=basic, status=401)
                assert 'Symphony task queue' in request('/tasks', auth=basic)
                assert api('snapshot')['runs'] == []
                preview = api('commands', {'op': 'preview', 'revision': 1, 'key': 'preview'})
                command = {'op': 'start', 'revision': 1, 'key': 'start', 'approval': preview['id']}
                run = api('commands', command)
                assert api('commands', command)['id'] == run['id']
                cli = subprocess.run([str(ROOT / 'cli/symphonyctl'), 'runs', 'list', '--json'],
                    env=env, capture_output=True, text=True, check=True)
                assert json.loads(cli.stdout)[0]['id'] == run['id']
                sync = [str(ROOT / 'cli/symphonyctl'), 'sync', '--revision', '2']
                count = sum(event['op'] == 'sync' for event in api('snapshot')['events'])
                for _ in range(2):
                    subprocess.run(sync + ['--key', 'repeatable-sync'], env=env,
                                   capture_output=True, text=True, check=True)
                assert sum(event['op'] == 'sync' for event in api('snapshot')['events']) == count + 1
                for _ in range(2):
                    subprocess.run(sync, env=env, capture_output=True, text=True, check=True)
                assert sum(event['op'] == 'sync' for event in api('snapshot')['events']) == count + 3
                api('commands', {'op': 'hold', 'revision': 2, 'key': 'hold'})
                deadline = time.monotonic() + 10
                while time.monotonic() < deadline:
                    before = api('snapshot')
                    if before['runs'][0]['state'] == 'succeeded':
                        break
                    time.sleep(.1)
                else:
                    raise AssertionError('Simulation did not complete')
                assert before['runs'][0]['evidence']['simulated'] is True
                assert before['task']['release_verified'] is False
                stop()
                launch()
                after = api('snapshot')
                assert after == before, 'SQLite state did not survive process restart'
                assert api('commands', command)['id'] == run['id'], 'Idempotency did not survive restart'
                print('PASS: HTTP auth, HTML rendering, approval/start, duplicate replay, CLI parity,')
                print('simulated completion, durable hold/history and process restart persistence.')
                print('Browser interaction is covered separately by LiveView tests and browser screenshots.')
            finally:
                stop()


if __name__ == '__main__':
    main()
