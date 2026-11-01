"""Synthetic public keys/configs only; no SSH commands, real keys or connections."""
import base64
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from cryptography.hazmat.primitives.asymmetric import ed25519
from cryptography.hazmat.primitives.serialization import (
    Encoding, PublicFormat, SSHCertificateBuilder, SSHCertificateType,
)

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import ssh_diagnostics as diagnostics


class SSHDiagnostics(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory(prefix="nixi-ssh-diagnostic-")
        self.addCleanup(scratch.cleanup)
        self.home = Path(scratch.name)
        (self.home / ".ssh").mkdir()
        self.config = self.home / ".ssh/config"
        self.trust = self.home / ".ssh/nixi_known_hosts"
        self.cert = self.home / "certificate.pub"
        self.key = ed25519.Ed25519PrivateKey.generate()
        self.public = self.key.public_key().public_bytes(Encoding.OpenSSH, PublicFormat.OpenSSH)
        self.trust.write_bytes(b"@cert-authority *.example.invalid " + self.public + b"\n")

    def cert_bytes(self, kind=SSHCertificateType.USER, after=900, before=1100):
        return (SSHCertificateBuilder().public_key(self.key.public_key()).type(kind)
                .valid_principals([b"fixture"]).valid_after(after).valid_before(before)
                .sign(ed25519.Ed25519PrivateKey.generate()).public_bytes())

    def reference(self, text):
        self.config.write_text(text)
        return diagnostics.trust(self.trust, self.config, self.home)["status"]

    def test_comments_quoted_paths_case_and_first_value(self):
        self.assertEqual(self.reference('# UserKnownHostsFile ~/.ssh/nixi_known_hosts\n'), "missing-reference")
        self.assertEqual(self.reference('Host *\n USERKNOWNHOSTSFILE = "~/.ssh/nixi_known_hosts"\n'), "configured")
        self.assertEqual(self.reference('UserKnownHostsFile ~/.ssh/other\nHost *\nUserKnownHostsFile ~/.ssh/nixi_known_hosts\n'), "missing-reference")
        self.assertEqual(self.reference('UserKnownHostsFile none\nUserKnownHostsFile ~/.ssh/nixi_known_hosts\n'), "missing-reference")

    def test_includes_order_missing_glob_and_relative_base(self):
        snippets = self.home / ".ssh/config.d"
        snippets.mkdir()
        (snippets / "20-second.conf").write_text('Host *\nUserKnownHostsFile ~/.ssh/nixi_known_hosts\n')
        self.assertEqual(self.reference('Include "config.d/*.conf"\nInclude absent-*.conf\n'), "configured")
        (snippets / "10-first.conf").write_text('UserKnownHostsFile ~/.ssh/other\n')
        self.assertEqual(self.reference('Include config.d/*.conf\n'), "missing-reference")
        (snippets / "10-first.conf").unlink()
        self.assertEqual(self.reference('# Include config.d/*.conf\n'), "missing-reference")

    def test_conditional_policy_is_unverified_without_execution(self):
        marker = self.home / "must-not-exist"
        for text in [f'Match exec "touch {marker}"\nUserKnownHostsFile ~/.ssh/nixi_known_hosts\n',
                     'Host example.invalid\nUserKnownHostsFile ~/.ssh/nixi_known_hosts\n',
                     'Host example.invalid\nInclude config.d/*\n',
                     'UserKnownHostsFile ${HOME}/.ssh/nixi_known_hosts\n',
                     'UserKnownHostsFile ~/.ssh/%h/nixi_known_hosts\n']:
            with self.subTest(text=text):
                self.assertEqual(self.reference(text), "unverified")
                self.assertFalse(marker.exists())

    def test_include_cycles_counts_and_aggregate_bytes_are_bounded(self):
        self.config.write_text('Include config\n')
        with self.assertRaises(ValueError):
            diagnostics.trust(self.trust, self.config, self.home)
        snippets = self.home / ".ssh/config.d"
        snippets.mkdir()
        for index in range(64):
            (snippets / str(index)).write_text('# fixture\n')
        self.config.write_text('Include config.d/*\n')
        with self.assertRaises(ValueError):
            diagnostics.trust(self.trust, self.config, self.home)
        self.config.write_text('Include config.d/0 config.d/1\n')
        for index in (0, 1):
            (snippets / str(index)).write_text('#' + 'x' * (512 * 1024))
        with self.assertRaises(ValueError):
            diagnostics.trust(self.trust, self.config, self.home)

    def test_public_ca_validation_missing_and_dangling_files(self):
        for data in [b'@cert-authority *.example.invalid not-a-key\n',
                     b'@cert-authority , ' + self.public,
                     b'# @cert-authority *.example.invalid ' + self.public,
                     b'@cert-authority *.example.invalid ' + self.cert_bytes()]:
            with self.assertRaises(ValueError):
                diagnostics.ca_entries(data)
        self.trust.unlink()
        self.assertEqual(diagnostics.trust(self.trust, self.config, self.home)["status"], "absent")
        self.trust.symlink_to(self.home / "missing")
        with self.assertRaises(ValueError):
            diagnostics.trust(self.trust, self.config, self.home)

    def test_certificate_signature_type_and_validity(self):
        self.cert.write_bytes(self.cert_bytes())
        self.assertEqual(diagnostics.certificate(self.cert, "user", now=1000)["status"], "configured")
        for kind, now in [("host", 1000), ("user", 899), ("user", 1100)]:
            with self.assertRaises(ValueError):
                diagnostics.certificate(self.cert, kind, now=now)
        parts = self.cert_bytes().split()
        blob = bytearray(base64.b64decode(parts[1]))
        blob[-1] ^= 1
        self.cert.write_bytes(parts[0] + b' ' + base64.b64encode(blob))
        with self.assertRaises(Exception):
            diagnostics.certificate(self.cert, "user", now=1000)
        self.cert.write_bytes(self.public)
        with self.assertRaises(ValueError):
            diagnostics.certificate(self.cert, "user", now=1000)

    def test_cli_redacts_and_rejects_special_or_large_inputs(self):
        fifo = self.home / "fifo"
        os.mkfifo(fifo)
        self.cert.write_bytes(b'x' * (1024 * 1024 + 1))
        invalid = self.home / "invalid"
        invalid.write_text('SYNTHETIC_PRIVATE_VALUE')
        for file in (fifo, self.home, self.cert, invalid):
            result = subprocess.run([sys.executable, diagnostics.__file__, 'user', str(file)],
                                    capture_output=True, text=True, timeout=7)
            self.assertEqual(result.returncode, 1)
            self.assertEqual(result.stdout, '')
            self.assertNotIn('SYNTHETIC_PRIVATE_VALUE', result.stderr)
            self.assertNotIn('Traceback', result.stderr)


if __name__ == "__main__":
    unittest.main()
