"""Parser-to-HTTP regression tests for IDs emitted by both fixture backends."""
import contextlib
import importlib.machinery
import importlib.util
import io
import json
import os
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import pathlib
import sys
import unittest
from unittest.mock import patch

loader = importlib.machinery.SourceFileLoader("symphonyctl", str(pathlib.Path(__file__).with_name("symphonyctl")))
spec = importlib.util.spec_from_loader(loader.name, loader)
cli = importlib.util.module_from_spec(spec)
loader.exec_module(cli)


class IdentifierTests(unittest.TestCase):
    def invoke(self, args, response):
        output = io.StringIO()
        with patch.object(sys, "argv", ["symphonyctl", *args]), patch.object(cli, "request", side_effect=response) as request, contextlib.redirect_stdout(output):
            cli.main()
        return request.call_args_list, output.getvalue()

    def test_leading_hyphen_run_mutations_and_approval(self):
        for run_id in ("-" + "A" * 23, "--" + "B" * 22):
            for action in ("stop", "retry", "resume"):
                with self.subTest(run_id=run_id, action=action):
                    calls, _ = self.invoke(["runs", action, run_id, "--revision", "2", "--approval", run_id, "--key", run_id, "--json"], lambda path, payload: payload)
                    self.assertEqual(calls[0].args[0], "commands")
                    payload = calls[0].args[1]
                    self.assertEqual(payload["run_id"], run_id)
                    self.assertEqual(payload["approval"], run_id)
                    self.assertEqual(payload["key"], run_id)
                    self.assertEqual(payload["op"], action)

    def test_leading_hyphen_run_reads(self):
        for run_id in ("-" + "A" * 23, "--" + "B" * 22):
            for action in ("list", "show", "history", "logs"):
                with self.subTest(run_id=run_id, action=action):
                    def response(path):
                        if path.startswith("events"):
                            return {"items": [{"result": {"id": run_id}}], "cursor": 1}
                        return {"runs": [{"id": run_id, "state": "stopped"}]}
                    _, output = self.invoke(["runs", action, run_id, "--json"], response)
                    self.assertIn(run_id, output)

    def test_logs_follow_keeps_identifier(self):
        run_id = "--" + "F" * 22
        def response(path):
            if path.startswith("events"):
                return {"items": [{"result": {"id": run_id}}], "cursor": 1}
            return {"runs": [{"id": run_id, "state": "running"}]}
        output = io.StringIO()
        with patch.object(sys, "argv", ["symphonyctl", "runs", "logs", run_id, "--follow"]), patch.object(cli, "request", side_effect=response), patch.object(cli.time, "sleep", side_effect=KeyboardInterrupt), contextlib.redirect_stdout(output):
            with self.assertRaises(KeyboardInterrupt):
                cli.main()
        self.assertIn(run_id, output.getvalue())

    def test_real_cli_sends_leading_hyphen_ids_over_http(self):
        run_id = "--" + "W" * 22
        received = []
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass
            def respond(self, payload):
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps(payload).encode())
            def do_POST(self):
                payload = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                received.append(payload)
                self.respond(payload)
            def do_GET(self):
                if "events?" in self.path:
                    self.respond({"items": [{"result": {"id": run_id}}], "cursor": 1})
                else:
                    self.respond({"runs": [{"id": run_id, "state": "stopped"}]})
        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            env = dict(os.environ, SYMPHONY_URL=f"http://127.0.0.1:{server.server_port}", SYMPHONY_DEMO_TOKEN="test-token")
            for action in ("stop", "retry", "resume", "list", "show", "history", "logs"):
                args = [sys.executable, cli.__file__, "runs", action, run_id, "--json"]
                if action in ("stop", "retry", "resume"):
                    args += ["--revision", "2", "--approval", run_id]
                result = subprocess.run(args, env=env, capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(run_id, result.stdout)
            self.assertEqual(len(received), 3)
            for payload in received:
                self.assertEqual(payload["run_id"], run_id)
                self.assertEqual(payload["approval"], run_id)
        finally:
            server.shutdown()
            server.server_close()
            thread.join()

    def test_global_flags_and_opaque_approval_values(self):
        calls, _ = self.invoke(["--json", "runs", "stop", "-run", "--revision", "2"], lambda path, payload: payload)
        self.assertEqual(calls[0].args[1]["run_id"], "-run")
        calls, _ = self.invoke(["runs", "retry", "-run", "--revision", "2", "--approval", "-preview", "--key", "--opaque-key"], lambda path, payload: payload)
        self.assertEqual(calls[0].args[1]["approval"], "-preview")
        self.assertEqual(calls[0].args[1]["key"], "--opaque-key")

    def test_unambiguous_abbreviations_and_missing_values(self):
        cases = [
            ["--j", "runs", "retry", "-run", "--rev", "2", "--app", "-preview", "--ke", "-key"],
            ["runs", "retry", "-run", "--rev=2", "--app=-preview", "--ke=-key", "--j"],
        ]
        for args in cases:
            calls, _ = self.invoke(args, lambda path, payload: payload)
            self.assertEqual(calls[0].args[1]["revision"], 2)
            self.assertEqual(calls[0].args[1]["approval"], "-preview")
            self.assertEqual(calls[0].args[1]["key"], "-key")
        with patch.object(sys, "argv", ["symphonyctl", "runs", "retry", "-run", "--app", "--rev", "2"]), patch.object(cli, "request") as request, contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as result:
                cli.main()
            self.assertEqual(result.exception.code, 2)
            request.assert_not_called()

    def test_existing_ids_options_and_explicit_terminator(self):
        cases = [
            (["runs", "stop", "normal-id", "--revision", "2"], "normal-id"),
            (["--revision", "2", "runs", "stop", "--", "-legacy-id"], "-legacy-id"),
            (["runs", "stop", "--revision", "2", "--", "--json"], "--json"),
        ]
        for args, identifier in cases:
            calls, _ = self.invoke(args, lambda path, payload: payload)
            self.assertEqual(calls[0].args[1]["run_id"], identifier)

    def test_unknown_options_still_fail_before_request(self):
        with patch.object(sys, "argv", ["symphonyctl", "runs", "list", "known-id", "--typo"]), patch.object(cli, "request") as request, contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as result:
                cli.main()
            self.assertEqual(result.exception.code, 2)
            request.assert_not_called()


if __name__ == "__main__":
    unittest.main()
