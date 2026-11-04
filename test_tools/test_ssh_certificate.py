"""Real cryptographic and CLI tests; synthetic keys, no root or live services."""
import fcntl
import grp
import json
import os
from pathlib import Path
import pwd
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric import ec, ed25519, rsa
from cryptography.hazmat.primitives.serialization import (
    Encoding, PublicFormat, SSHCertificateBuilder, SSHCertificateType,
)

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import ssh_certificate as certificate


class CertificateValidation(unittest.TestCase):
    def setUp(self):
        self.ca = ed25519.Ed25519PrivateKey.generate()
        self.key = ed25519.Ed25519PrivateKey.generate().public_key()
        self.public = self.key.public_bytes(Encoding.OpenSSH, PublicFormat.OpenSSH)

    def signed(self, kind=SSHCertificateType.HOST, key=None, after=100, before=200, principals=None):
        return (SSHCertificateBuilder().public_key(key or self.key).type(kind)
                .valid_after(after).valid_before(before)
                .valid_principals(principals or [b"fixture"])
                .sign(self.ca).public_bytes())

    def validate(self, data):
        certificate.validate_certificate(data, self.public, "host", ["fixture"], now=150)

    def test_valid_certificate_and_signature(self):
        self.validate(self.signed())

    def test_rsa_and_ecdsa_keys_and_ca_signatures(self):
        for ca in (rsa.generate_private_key(public_exponent=65537, key_size=2048),
                   ec.generate_private_key(ec.SECP256R1())):
            self.ca = ca
            self.key = ca.public_key()
            self.public = self.key.public_bytes(Encoding.OpenSSH, PublicFormat.OpenSSH)
            self.validate(self.signed())

    def test_rejects_wrong_type_key_time_and_principals(self):
        for data in (b"invalid", self.public, self.signed(kind=SSHCertificateType.USER),
                     self.signed(key=ed25519.Ed25519PrivateKey.generate().public_key()),
                     self.signed(before=150), self.signed(after=151),
                     self.signed(principals=[b"other"]), self.signed() + b"\n" + self.signed()):
            with self.subTest(data_kind=data.split()[0]):
                with self.assertRaises(ValueError):
                    self.validate(data)

    def test_tampered_signature_is_rejected(self):
        import base64
        kind, body = self.signed().split()
        raw = bytearray(base64.b64decode(body))
        raw[-1] ^= 1
        with self.assertRaises(InvalidSignature):
            self.validate(kind + b" " + base64.b64encode(raw))

    def test_public_key_requires_one_unsigned_record(self):
        for data in (b"", b" \n", self.signed(), self.public + b"\n" + self.public, b"sk-ssh-ed25519@openssh.com fixture"):
            with self.assertRaises(ValueError):
                certificate.public_key(data)

    def test_public_key_worker_drops_privileges_before_reading(self):
        events = []
        with (patch.object(certificate, "drop_privileges", side_effect=lambda *args: events.append("drop")),
              patch.object(certificate, "read_bounded", side_effect=lambda *args: (events.append("read") or b"")),
              patch.object(certificate.resource, "setrlimit")):
            self.assertEqual(certificate.main(["read-user-key", "--user", "fixture", "--group", "fixture", "--public-key", "/fixture"]), 0)
        self.assertEqual(events, ["drop", "read"])

    def test_anonymous_ca_snapshot_is_private_and_closed_on_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(RuntimeError, "synthetic interruption"):
                with certificate.anonymous_ca(b"synthetic-private-snapshot", directory) as fd:
                    info = os.fstat(fd)
                    self.assertEqual(stat.S_IMODE(info.st_mode), 0o600)
                    self.assertEqual(info.st_nlink, 0)
                    self.assertEqual(list(Path(directory).iterdir()), [])
                    self.assertEqual(os.read(fd, 1024), b"synthetic-private-snapshot")
                    if hasattr(os, "memfd_create"):
                        self.assertTrue(fcntl.fcntl(fd, fcntl.F_GET_SEALS) & fcntl.F_SEAL_WRITE)
                        with self.assertRaises(OSError):
                            os.write(fd, b"replace")
                    raise RuntimeError("synthetic interruption")
            with self.assertRaises(OSError):
                os.fstat(fd)


class CertificateCLI(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="nixi-ssh-certificate-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.tool = os.environ["NIXI_CERTIFICATE_TOOL"]
        self.user = pwd.getpwuid(os.geteuid()).pw_name
        self.group = grp.getgrgid(os.getegid()).gr_name
        for name in ("ca", "key", "other"):
            self.keygen("-t", "ed25519", "-N", "", "-f", str(self.root / name))
        self.destination = self.root / "installed-cert.pub"
        self.destination.write_bytes(b"previous-certificate")

    def keygen(self, *args):
        return subprocess.run(["ssh-keygen", "-q", *args], capture_output=True, timeout=10, check=True)

    def run_tool(self, *args, expected=0, deadline=8):
        result = subprocess.run([self.tool, *args, "--runtime-directory", str(self.root)],
                                capture_output=True, timeout=deadline)
        self.assertEqual(result.returncode, expected, result.stderr.decode())
        self.assertEqual(list(self.root.glob("nixi-ssh-cert-*")), [])
        return result

    def arguments(self, command="user", source=False):
        return [command, "--public-key", str(self.root / "key.pub"),
                "--certificate", str(self.destination), "--principals", '["fixture"]',
                *( ["--source-file", str(self.root / "source.pub")] if source else ["--ca-key", str(self.root / "ca")]),
                *( ["--user", self.user, "--group", self.group, "--required"] if command == "user" else [])]

    def assert_preserved(self):
        self.assertEqual(self.destination.read_bytes(), b"previous-certificate")

    def test_real_user_signing_renewal_and_permissions(self):
        self.run_tool(*self.arguments())
        first = self.destination.read_bytes()
        certificate.validate_certificate(first, (self.root / "key.pub").read_bytes(), "user", ["fixture"])
        self.assertEqual(self.destination.stat().st_mode & 0o777, 0o644)
        self.run_tool(*self.arguments())
        self.assertNotEqual(first, self.destination.read_bytes())

    def test_real_host_signing_and_presigned_installation(self):
        self.run_tool(*self.arguments("host"))
        data = self.destination.read_bytes()
        (self.root / "source.pub").write_bytes(data)
        self.destination.write_bytes(b"previous-certificate")
        self.run_tool(*self.arguments("host", source=True))
        self.assertEqual(self.destination.read_bytes(), data)

    def test_signer_receives_anonymous_ca_descriptor(self):
        signer = self.root / "descriptor-signer"
        real_keygen = shutil.which("ssh-keygen")
        signer.write_text(f'''#!{sys.executable}
import os, stat, sys
from pathlib import Path
args = sys.argv[1:]
source = args[args.index("-s")+1]
assert source.startswith("/dev/fd/")
fd = int(source.rsplit("/", 1)[1])
info = os.fstat(fd)
assert stat.S_ISREG(info.st_mode) and info.st_nlink == 0
assert stat.S_IMODE(info.st_mode) == 0o600
assert "ca" not in [p.name for p in Path(args[-1]).parent.iterdir()]
os.execv({real_keygen!r}, [{real_keygen!r}, *args])
''')
        signer.chmod(0o755)
        self.run_tool("--ssh-keygen", str(signer), *self.arguments())
        certificate.validate_certificate(self.destination.read_bytes(),
                                         (self.root / "key.pub").read_bytes(), "user", ["fixture"])

    def test_invalid_presigned_material_preserves_destination(self):
        self.keygen("-s", str(self.root / "ca"), "-I", "fixture", "-n", "fixture", "-V", "+1h", str(self.root / "other.pub"))
        user_cert = (self.root / "other-cert.pub").read_bytes()
        self.keygen("-s", str(self.root / "ca"), "-h", "-I", "fixture", "-n", "fixture", "-V", "+1h", str(self.root / "other.pub"))
        other_host_cert = (self.root / "other-cert.pub").read_bytes()
        for data in (b"invalid\n", user_cert, other_host_cert):
            (self.root / "source.pub").write_bytes(data)
            self.run_tool(*self.arguments("host", source=True), expected=1)
            self.assert_preserved()

    def test_fifo_and_symlink_to_fifo_rejected_without_hanging(self):
        key = self.root / "key.pub"
        key.unlink()
        os.mkfifo(key)
        self.run_tool(*self.arguments(), expected=1)
        self.assert_preserved()
        key.rename(self.root / "fifo")
        key.symlink_to(self.root / "fifo")
        self.run_tool(*self.arguments(), expected=1)
        self.assert_preserved()

    def test_large_public_key_rejected_before_installing(self):
        (self.root / "key.pub").write_bytes(b"x" * (certificate.MAX_INPUT + 1))
        self.run_tool(*self.arguments(), expected=1)
        self.assert_preserved()

    def test_fifo_presigned_source_rejected_without_hanging(self):
        os.mkfifo(self.root / "source.pub")
        self.run_tool(*self.arguments("host", source=True), expected=1)
        self.assert_preserved()

    def test_python_environment_cannot_inject_code_or_replace_worker(self):
        injection = self.root / "injection"
        injection.mkdir()
        marker = self.root / "unexpected-import"
        (injection / "injected.pth").write_text(f"import pathlib; pathlib.Path({str(marker)!r}).touch()\n")
        with patch.dict(os.environ, {"NIX_PYTHONPATH": str(injection),
                                     "NIX_PYTHONEXECUTABLE": "/not-a-python-interpreter",
                                     "PYTHONEXECUTABLE": "/not-a-python-interpreter",
                                     "PYTHONPATH": str(injection)}):
            self.run_tool(*self.arguments())
        self.assertFalse(marker.exists())

    def test_readable_public_key_symlink_still_works(self):
        (self.root / "key.pub").rename(self.root / "saved.pub")
        (self.root / "key.pub").symlink_to(self.root / "saved.pub")
        self.run_tool(*self.arguments())

    def test_optional_missing_input_skips_and_required_fails(self):
        (self.root / "ca").unlink()
        args = self.arguments()
        self.run_tool(*args, expected=3)
        args.remove("--required")
        result = self.run_tool(*args)
        self.assertIn(b"skipping cert signing", result.stdout)
        self.assert_preserved()

    def test_encrypted_ca_fails_without_askpass_or_prompt(self):
        (self.root / "ca").unlink()
        self.keygen("-t", "ed25519", "-N", "synthetic-password", "-f", str(self.root / "ca"))
        self.run_tool(*self.arguments(), expected=1)
        self.assert_preserved()

    def test_overall_deadline_stops_signer_and_keeps_previous_certificate(self):
        sleeper = self.root / "sleeper"
        pid_file = self.root / "signer-pid"
        sleeper.write_text(f"#!{shutil.which('python3')}\nimport os,time\nfrom pathlib import Path\nPath({str(pid_file)!r}).write_text(str(os.getpid()))\ntime.sleep(20)\n")
        sleeper.chmod(0o755)
        self.run_tool("--ssh-keygen", str(sleeper), *self.arguments(), "--timeout", "2", expected=1)
        self.assert_preserved()
        with self.assertRaises(ProcessLookupError):
            os.kill(int(pid_file.read_text()), 0)


if __name__ == "__main__":
    unittest.main()
