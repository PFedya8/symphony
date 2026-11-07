#!/usr/bin/env python3
"""Argument parsing and local HTTP regressions for the shared CLI's opaque identifier parsing."""
import contextlib
import io
import json
import os
from http.server import BaseHTTPRequestHandler, HTTPServer
import subprocess
import threading
from pathlib import Path
import runpy
import sys
import unittest
from unittest.mock import Mock, patch

CLI = runpy.run_path(str(Path(__file__).resolve().parents[1] / 'cli/symphonyctl'))


class IdentifierTests(unittest.TestCase):
    def invoke(self, arguments, response):
        request = Mock(return_value=response)
        with patch.object(sys, 'argv', ['symphonyctl', *arguments]), \
                patch.dict(CLI['main'].__globals__, request=request), \
                contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            CLI['main']()
        return request

    def test_stop_preserves_leading_hyphens_before_and_after_options(self):
        for identifier in ['-leading-run', '--leading-run']:
            for args in [['runs', 'stop', identifier, '--revision', '2'],
                         ['runs', 'stop', '--revision', '2', identifier],
                         ['runs', 'stop', '--revision=2', identifier],
                         ['runs', 'stop', '--revision', '2', '--', identifier]]:
                with self.subTest(args=args):
                    request = self.invoke(args, {'state': 'stopping'})
                    self.assertEqual(request.call_args.args[1]['run_id'], identifier)
                    self.assertEqual(request.call_args.args[1]['revision'], 2)

    def test_global_flags_do_not_shift_identifier_detection(self):
        for args in [['--json', 'runs', 'stop', '-run', '--revision', '2'],
                     ['runs', '--json', 'stop', '-run', '--revision', '2'],
                     ['--revision', '2', '--json', 'runs', 'stop', '--run'],
                     ['--j', 'runs', 'stop', '-run', '--rev', '2']]:
            with self.subTest(args=args):
                request = self.invoke(args, {})
                self.assertIn(request.call_args.args[1]['run_id'], ['-run', '--run'])
                self.assertEqual(request.call_args.args[1]['revision'], 2)

    def test_leading_hyphen_approval_and_key_values(self):
        for approval in ['-preview', '--preview']:
            for option in [['--approval', approval], ['--approval=' + approval]]:
                with self.subTest(option=option):
                    request = self.invoke(['--json', 'runs', 'retry', '-run', '--revision', '2',
                                           *option, '--key', '-key'], {})
                    self.assertEqual(request.call_args.args[1]['approval'], approval)
                    self.assertEqual(request.call_args.args[1]['key'], '-key')

    def test_missing_option_value_does_not_consume_another_option(self):
        for args in [['runs', 'retry', '-run', '--approval', '--revision', '2'],
                     ['runs', 'retry', '-run', '--revision', '2', '--approval']]:
            with self.subTest(args=args), self.assertRaises(SystemExit) as error:
                self.invoke(args, {})
            self.assertEqual(error.exception.code, 2)

    def test_retry_preserves_identifier_approval_and_key(self):
        request = self.invoke(['runs', 'retry', '-run', '--revision', '3',
                               '--approval', 'preview', '--key', 'stable'], {})
        self.assertEqual(request.call_args.args[1]['run_id'], '-run')
        self.assertEqual(request.call_args.args[1]['approval'], 'preview')
        self.assertEqual(request.call_args.args[1]['key'], 'stable')

    def test_show_preserves_identifier(self):
        request = self.invoke(['runs', 'show', '--opaque-run', '--json'],
                              {'runs': [{'id': '--opaque-run'}]})
        request.assert_called_once_with('snapshot')

    def test_existing_normal_id_and_flags_are_unchanged(self):
        request = self.invoke(['tasks', 'start', 'fixture-1', '--dry-run', '--revision', '1'], {})
        self.assertEqual(request.call_args.args[1]['task_id'], 'fixture-1')
        self.assertEqual(request.call_args.args[1]['op'], 'preview')

    def test_board_mutations_forward_fields_and_types(self):
        cases = [
            (['tasks', 'create', '--title', 'New work', '--project', 'other', '--revision', '1'],
             {'op': 'create', 'title': 'New work', 'project': 'other', 'task_id': None}),
            (['tasks', 'move', 'task-1', '--stage', 'Human Review', '--revision', '2'],
             {'op': 'move', 'stage': 'Human Review', 'task_id': 'task-1'}),
            (['tasks', 'plan', 'task-1', '--text', 'Inspect\nVerify', '--revision', '3'],
             {'op': 'plan', 'text': 'Inspect\nVerify'}),
            (['tasks', 'check', 'task-1', '--step', '0', '--completed', 'false', '--revision', '4'],
             {'op': 'check', 'step': 0, 'completed': False}),
            (['tasks', 'link', 'task-1', '--kind', 'walkthrough', '--title', 'Evidence',
              '--url', 'https://example.com/guide', '--revision', '5'],
             {'op': 'link', 'kind': 'walkthrough', 'url': 'https://example.com/guide'}),
        ]
        for args, expected in cases:
            with self.subTest(args=args):
                request = self.invoke(args, {})
                self.assertEqual(request.call_args.args[0], 'commands')
                for key, value in expected.items():
                    self.assertEqual(request.call_args.args[1][key], value)

    def test_board_and_multitask_reads(self):
        snapshot = {'board_revision': 2, 'task': {'id': 'fixture-1'}, 'events': [],
                    'tasks': [{'id': 'fixture-1', 'project': 'demo'}, {'id': 'task-2', 'project': 'other'}]}
        for args in [['tasks', 'board', '--json'], ['tasks', 'list', '--project', 'other', '--json'],
                     ['tasks', 'show', 'task-2', '--json'], ['tasks', 'history', 'task-2']]:
            with self.subTest(args=args):
                self.invoke(args, snapshot).assert_called_once_with('snapshot')

    def test_reported_variants_reach_real_http_with_unchanged_values(self):
        received = []

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                received.append(json.loads(self.rfile.read(int(self.headers['Content-Length']))))
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(b'{}')

            def log_message(self, *_args):
                pass

        with HTTPServer(('127.0.0.1', 0), Handler) as server:
            worker = threading.Thread(target=server.serve_forever, daemon=True)
            worker.start()
            try:
                env = dict(os.environ, SYMPHONY_URL=f'http://127.0.0.1:{server.server_port}',
                           SYMPHONY_DEMO_TOKEN='synthetic-cli-test-only')
                for args in [['--json', 'runs', 'stop', '-run', '--revision', '2'],
                             ['runs', 'retry', '-run', '--revision', '2', '--approval', '-preview']]:
                    result = subprocess.run([sys.executable, str(Path(__file__).resolve().parents[1] / 'cli/symphonyctl'),
                                             *args], env=env, capture_output=True, text=True, timeout=10)
                    self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual([body['run_id'] for body in received], ['-run', '-run'])
                self.assertEqual(received[1]['approval'], '-preview')
            finally:
                server.shutdown()
                worker.join(timeout=5)

    def test_missing_revision_still_fails_before_transport(self):
        with self.assertRaises(SystemExit) as error:
            self.invoke(['runs', 'stop', '-run'], {})
        self.assertEqual(error.exception.code, 2)

    def test_unknown_extra_option_still_fails(self):
        with self.assertRaises(SystemExit) as error:
            self.invoke(['runs', 'stop', 'run', '--revision', '2', '--typo'], {})
        self.assertEqual(error.exception.code, 2)


if __name__ == '__main__':
    unittest.main()
