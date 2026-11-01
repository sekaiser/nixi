"""Regression tests using only temporary dummy OpenVPN credentials."""
from pathlib import Path
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import openvpn_credentials as credentials


class Credentials(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="nixi-openvpn-")
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        self.username = self.root / "user name ' $(literal)"
        self.password = self.root / 'password " file'
        self.output = self.root / "auth-user-pass"
        self.username.write_bytes(b"fixture-user")
        self.password.write_bytes(b"fixture-password")

    def install(self):
        credentials.install(self.username, self.password, self.output)

    def test_line_endings_and_whitespace(self):
        for first in (b"", b"\n", b"\r\n"):
            for second in (b"", b"\n", b"\r\n"):
                with self.subTest(first=first, second=second):
                    self.username.write_bytes(b" user with spaces " + first)
                    self.password.write_bytes(b" password with spaces " + second)
                    self.install()
                    self.assertEqual(self.output.read_bytes(),
                                     b" user with spaces \n password with spaces \n")
                    self.assertEqual(stat.S_IMODE(self.output.stat().st_mode), 0o400)
                    self.assertEqual(list(self.root.glob(".auth-user-pass-*")), [])

    def test_invalid_input_does_not_replace_existing_credentials(self):
        self.output.write_bytes(b"old credentials")
        for source in (self.username, self.password):
            for content in (b"", b"\n", b"\r\n", b"one\ntwo", b"one\n\n", b"one\rtwo", b"one\0two"):
                with self.subTest(source=source.name, content=content):
                    self.username.write_bytes(b"fixture-user")
                    self.password.write_bytes(b"fixture-password")
                    source.write_bytes(content)
                    with self.assertRaises(ValueError):
                        self.install()
                    self.assertEqual(self.output.read_bytes(), b"old credentials")
        self.password.unlink()
        with self.assertRaises(OSError):
            self.install()
        self.assertEqual(self.output.read_bytes(), b"old credentials")
        self.assertEqual(list(self.root.glob(".auth-user-pass-*")), [])

    def test_atomic_failure_cleans_temporary_file(self):
        self.output.write_bytes(b"old credentials")
        with patch.object(credentials.os, "replace", side_effect=OSError("fixture failure")), self.assertRaises(OSError):
                self.install()
        self.assertEqual(self.output.read_bytes(), b"old credentials")
        self.assertEqual(list(self.root.glob(".auth-user-pass-*")), [])

    def test_special_and_oversize_sources_leave_credentials_unchanged(self):
        self.output.write_text("previous")
        fifo = self.root / "fifo"
        os.mkfifo(fifo)
        oversized = self.root / "oversized"
        oversized.write_bytes(b"x" * 65537)
        for path in (fifo, self.root, oversized):
            with self.assertRaises(ValueError):
                credentials.install(self.username, path, self.output)
            self.assertEqual(self.output.read_text(), "previous")

    def test_output_symlink_does_not_modify_referent(self):
        referent = self.root / "unrelated"
        referent.write_bytes(b"untouched")
        self.output.symlink_to(referent)
        self.install()
        self.assertFalse(self.output.is_symlink())
        self.assertEqual(referent.read_bytes(), b"untouched")

    def test_symlink_directory_is_rejected(self):
        link = self.root / "link"
        link.symlink_to(self.root, target_is_directory=True)
        with self.assertRaises(ValueError):
            credentials.install(self.username, self.password, link / "auth-user-pass")
        self.assertFalse(self.output.exists())

    def test_cli_failure_never_prints_credential_values(self):
        self.password.write_bytes(b"FIXTURE_SECRET\ninvalid")
        result = subprocess.run([sys.executable, credentials.__file__, str(self.username),
                                 str(self.password), str(self.output)],
                                capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 1)
        self.assertNotIn("FIXTURE_SECRET", result.stdout + result.stderr)
        self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main()
