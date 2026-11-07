#!/usr/bin/env python3
"""Real CLI/control API regression against an isolated local fixture and mutable HTTP source."""
import json
import os
from pathlib import Path
import subprocess
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer


def main():
    base = urllib.parse.urlsplit(os.environ.get('SYMPHONY_URL', 'http://127.0.0.1:4000'))
    if base.scheme != 'http' or base.hostname not in ('127.0.0.1', 'localhost', '::1'):
        raise ValueError('Disposable loopback-only fixture required')
    cli = str(Path(__file__).resolve().parents[1] / 'cli/symphonyctl')
    state = {'turn_count': 1, 'available': True, 'reads': 0}

    class Source(BaseHTTPRequestHandler):
        def do_GET(self):
            state['reads'] += 1
            self.send_response(200 if state['available'] else 503)
            self.end_headers()
            self.wfile.write(json.dumps({'issue_identifier': 'REPLAY-1', 'status': 'running',
                                        'running': {'turn_count': state['turn_count']}}).encode())

        def log_message(self, *_):
            pass

    server = HTTPServer(('127.0.0.1', 0), Source)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()

    def invoke(*args):
        result = subprocess.run([cli, *args], capture_output=True, text=True, check=False)
        assert result.returncode == 0, result.stderr
        return json.loads(result.stdout)

    try:
        before = invoke('tasks', 'show', 'fixture-1', '--json')
        key = 'import-replay-' + os.urandom(8).hex()
        args = ('tasks', 'import-runtime', 'fixture-1', '--source-url', f'http://127.0.0.1:{server.server_port}',
                '--issue', 'REPLAY-1', '--revision', str(before['revision']), '--key', key, '--json')
        receipt = invoke(*args)
        state['turn_count'] = 9
        assert invoke(*args) == receipt, 'Changed source must replay the original receipt'
        state['available'] = False
        assert invoke(*args) == receipt, 'Unavailable source must not prevent replay'
        server.shutdown()
        thread.join()
        server.server_close()
        assert invoke(*args) == receipt, 'Disappeared source must not prevent replay'
        assert state['reads'] == 1, 'Retries must not refetch a completed import'
        after = invoke('tasks', 'show', 'fixture-1', '--json')
        assert after['revision'] == before['revision'] + 1
        assert len(after['reports']) == len(before['reports']) + 1
        assert json.loads(receipt['text'])['running']['turn_count'] == 1
        print(json.dumps({'passed': True, 'source_reads': state['reads'], 'report_writes': 1,
                          'checks': ['changed source replay', 'unavailable/disappeared source replay', 'same receipt', 'one revision bump']}))
    finally:
        server.shutdown()
        thread.join()
        server.server_close()


if __name__ == '__main__':
    main()
