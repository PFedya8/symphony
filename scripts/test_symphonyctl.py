#!/usr/bin/env python3
"""Transport-free regressions for the shared CLI's opaque identifier parsing."""
import contextlib
import io
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
