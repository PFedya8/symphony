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
import tempfile
from types import SimpleNamespace
from unittest.mock import Mock, patch

CLI = runpy.run_path(str(Path(__file__).resolve().parents[1] / 'cli/symphonyctl'))


class EvidenceTests(unittest.TestCase):
    def test_agent_import_selects_only_reviewed_fields(self):
        with tempfile.NamedTemporaryFile(mode='w+', suffix='.json') as artifact:
            json.dump({'reference': 'commit abc', 'summary': 'Reviewed result', 'secret': 'must not forward'}, artifact)
            artifact.flush()
            result = CLI['import_evidence'](SimpleNamespace(action='import-agent', file=artifact.name))
        self.assertEqual(result['provider'], 'agent_artifact')
        self.assertNotIn('secret', json.dumps(result))
        with self.assertRaises(ValueError):
            CLI['import_evidence'](SimpleNamespace(action='import-agent', file=None))

    def test_agent_import_rejects_oversize_and_invalid_shape(self):
        for text in ['x' * 65537, '[]', '{"reference": 3, "summary":"bad"}']:
            with tempfile.NamedTemporaryFile(mode='w+', suffix='.json') as artifact:
                artifact.write(text); artifact.flush()
                with self.assertRaises(ValueError):
                    CLI['import_evidence'](SimpleNamespace(action='import-agent', file=artifact.name))

    def test_github_import_fetches_only_canonical_api_and_selects_fields(self):
        response = Mock()
        response.read.return_value = json.dumps({'number': 4, 'title': 'A PR', 'state': 'open', 'merged': False,
                                                'head': {'sha': 'abc'}, 'body': 'private body excluded'}).encode()
        response.__enter__ = Mock(return_value=response); response.__exit__ = Mock(return_value=False)
        opener = Mock(); opener.open.return_value = response
        with patch('urllib.request.build_opener', return_value=opener), patch.dict(os.environ, {'SYMPHONY_GITHUB_TOKEN': 'separate-provider-token'}):
            result = CLI['import_evidence'](SimpleNamespace(action='import-pr', url='https://github.com/owner/repo/pull/4'))
        req = opener.open.call_args.args[0]
        self.assertEqual(req.full_url, 'https://api.github.com/repos/owner/repo/pulls/4')
        self.assertEqual(result['provider'], 'github_api')
        self.assertNotIn('private body', result['text'])
        self.assertNotIn('separate-provider-token', json.dumps(result))

    def test_import_rejects_unsafe_sources(self):
        for url in ['https://evil.test/owner/repo/pull/1', 'http://github.com/owner/repo/pull/1', 'https://github.com/../repo/pull/1']:
            with self.assertRaises(ValueError):
                CLI['import_evidence'](SimpleNamespace(action='import-pr', url=url))
        for url in ['http://example.com:4000', 'http://user:pass@127.0.0.1:4000', 'http://127.0.0.1:4000/private', 'http://127.0.0.1']:
            with self.assertRaises(ValueError):
                CLI['import_evidence'](SimpleNamespace(action='import-runtime', source_url=url, issue='TASK-1'))
        with self.assertRaises(ValueError):
            CLI['NoRedirect']().redirect_request(None, None, 302, '', {}, 'https://evil.test')

    def test_runtime_import_reads_real_local_http_without_copying_logs_or_paths(self):
        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(200); self.end_headers()
                self.wfile.write(json.dumps({'issue_identifier':'TASK-1', 'status':'running', 'workspace':{'path':'private'},
                                             'running':{'state':'In Progress','turn_count':2,'last_message':'secret prompt','last_event':'turn_started'}}).encode())
            def log_message(self, *_):
                pass
        server = HTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
        try:
            result = CLI['import_evidence'](SimpleNamespace(action='import-runtime', source_url=f'http://127.0.0.1:{server.server_port}', issue='TASK-1'))
            self.assertEqual(result['provider'], 'runtime_snapshot')
            self.assertNotIn('private', result['text']); self.assertNotIn('secret', result['text'])
            self.assertEqual(json.loads(result['text'])['running']['turn_count'], 2)
        finally:
            server.shutdown(); thread.join(); server.server_close()


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
            (['tasks', 'worklog', 'task-1', '--plan-text', 'Plan', '--acceptance-text', 'Accept', '--validation-text', 'Tested', '--revision', '2'],
             {'op': 'worklog', 'plan_text': 'Plan', 'acceptance_text': 'Accept', 'validation_text': 'Tested'}),
            (['tasks', 'comment', 'task-1', '--text', 'Reply', '--parent-id', '-parent', '--revision', '2'],
             {'op': 'comment', 'text': 'Reply', 'parent_id': '-parent'}),
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
