"""Failure diagnostics preserve the packaged check and exclude private payloads."""

import json
import os
from pathlib import Path
import sys
import tempfile
import textwrap
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import integration


class PackagedHelperDiagnosticsTests(unittest.TestCase):
    def invoke_failing_helper(self, *, status=None, stderr="", symlink_status=False):
        canary = "private-fixture-password-never-log"
        with tempfile.TemporaryDirectory(prefix="helper-diagnostic-test-") as temporary:
            root = Path(temporary)
            home = root / "home"
            home.mkdir(mode=0o700)
            target = root / "outside-status.json"
            target.write_text(json.dumps(status))
            target.chmod(0o600)
            helper = root / "fake-helper"
            script = f"""\
                #!{sys.executable}
                import json, os, pathlib, sys
                session = pathlib.Path(sys.argv[3])
                status = {status!r}
                if status is not None:
                    if {symlink_status!r}:
                        (session / 'status.json').symlink_to({str(target)!r})
                    else:
                        descriptor = os.open(session / 'status.json', os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                        with os.fdopen(descriptor, 'w') as stream:
                            json.dump(status, stream)
                print({canary!r})
                print({stderr!r}, file=sys.stderr)
                raise SystemExit(7)
                """
            helper.write_text(textwrap.dedent(script))
            helper.chmod(0o700)
            fixtures = SimpleNamespace(username="private-fixture-user", password=canary,
                                       socks_port=12345, connect_port=12346)
            with patch.object(integration.Path, "home", return_value=home):
                with self.assertRaises(RuntimeError) as failure:
                    integration.check_product_compiler(helper, fixtures)
            # The request and synthetic credentials must be removed on failure.
            self.assertFalse((home / "Library/Application Support/App Proxy/Sessions").exists())
            self.assertEqual(list(home.rglob("request.json")), [])
            diagnostic = str(failure.exception)
            self.assertNotIn(canary, diagnostic)
            self.assertNotIn("private-fixture-user", diagnostic)
            self.assertNotIn("private-status-argument", diagnostic)
            self.assertNotIn("private-status-message", diagnostic)
            return diagnostic

    def test_allowlisted_structured_status_reports_key_and_exit_only(self):
        diagnostic = self.invoke_failing_helper(status={
            "messageContent": {"key": "helper.parent", "arguments": ["private-status-argument"]},
            "message": "private-status-message",
            "logs": ["private-fixture-password-never-log"],
        })
        self.assertIn("exit=7", diagnostic)
        self.assertIn("status=helper.parent", diagnostic)
        self.assertIn("source=status", diagnostic)
        self.assertIn("output_bytes=", diagnostic)

    def test_pre_session_failure_matches_only_exact_fixed_catalog_message(self):
        diagnostic = self.invoke_failing_helper(
            stderr="Invalid session parent directory ownership or permissions.")
        self.assertIn("status=error.session.parent_permissions", diagnostic)
        self.assertIn("source=stderr_catalog", diagnostic)

    def test_unknown_key_and_unmatched_stderr_are_withheld(self):
        diagnostic = self.invoke_failing_helper(
            status={"messageContent": {"key": "private-fixture-password-never-log"}},
            stderr="private-fixture-password-never-log")
        self.assertIn("status=unavailable", diagnostic)

    def test_status_symlink_is_not_followed(self):
        diagnostic = self.invoke_failing_helper(
            status={"messageContent": {"key": "helper.parent"}}, symlink_status=True)
        self.assertIn("status=unavailable", diagnostic)

    def test_placeholder_catalog_message_is_not_accepted_from_stderr(self):
        diagnostic = self.invoke_failing_helper(
            stderr="Cannot read the proxy password from Keychain: {0}")
        self.assertIn("status=unavailable", diagnostic)


if __name__ == "__main__":
    unittest.main()
