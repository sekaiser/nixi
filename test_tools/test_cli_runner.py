"""Tests for the isolated behavioral-test runner."""
import sys
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from run_cli_tests import run_isolated


class IsolatedRunnerTests(unittest.TestCase):
    def test_success_and_failure_status(self):
        status, output, failure = run_isolated([sys.executable, "-c", "print('fixture'); raise SystemExit(7)"])
        self.assertEqual(status, 7)
        self.assertIn("fixture", output)
        self.assertIsNone(failure)

    def test_deadline(self):
        status, _, failure = run_isolated([sys.executable, "-c", "import time; time.sleep(10)"], timeout=0.2)
        self.assertNotEqual(status, 0)
        self.assertEqual(failure, "test deadline exceeded")

    def test_output_limit(self):
        status, output, failure = run_isolated([sys.executable, "-c", "print('x' * 4096)"], output_limit=128)
        self.assertNotEqual(status, 0)
        self.assertLessEqual(len(output), 128)
        self.assertEqual(failure, "test output limit exceeded")

    def test_combined_output_limit_and_no_python_group_signalling(self):
        with patch("os.killpg", side_effect=AssertionError("only the native helper may signal groups")):
            status, output, failure = run_isolated(
                [sys.executable, "-c", "import os; os.write(1, b'x' * 80); os.write(2, b'y' * 80)"],
                output_limit=128)
        self.assertNotEqual(status, 0)
        self.assertLessEqual(len(output), 128)
        self.assertEqual(failure, "test output limit exceeded")

    def test_protocol_failure_closes_lifetime_pipe(self):
        with tempfile.TemporaryDirectory(prefix="nixi-runner-") as root:
            helper, marker = Path(root) / "helper", Path(root) / "cancelled"
            helper.write_text(f'''#!{sys.executable}
import os, signal, sys
from pathlib import Path
signal.alarm(3)
os.write(1, b"BAD!!!")
sys.stdin.buffer.read()
Path({str(marker)!r}).touch()
''')
            helper.chmod(0o700)
            with patch.dict(os.environ, HEY_PROCESS_SUPERVISOR=str(helper)):
                status, _, failure = run_isolated(["unused"], timeout=0.2)
            self.assertEqual(status, 1)
            self.assertEqual(failure, "invalid test supervisor protocol")
            self.assertTrue(marker.exists())


if __name__ == "__main__":
    unittest.main()
