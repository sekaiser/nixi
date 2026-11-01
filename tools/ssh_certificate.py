"""Bounded SSH certificate preparation; no user-path reads with root's authority."""
import argparse
import io
import json
import os
from pathlib import Path
import resource
import signal
import subprocess
import sys
import tempfile
import time

from cryptography.exceptions import InvalidSignature, UnsupportedAlgorithm
from cryptography.hazmat.primitives.serialization import (
    Encoding, PublicFormat, SSHCertificate, SSHCertificateType,
    load_ssh_public_identity,
)

from install_user_file import drop_privileges, install, open_source, replace_file, root_destination

MAX_INPUT = 1024 * 1024


class MissingInput(Exception):
    pass


class CertificateError(ValueError):
    """An actionable diagnostic which never includes input key material."""


def read_bounded(path):
    # Privileged callers use the installer's protected descriptor traversal.
    # A user-key reader must drop privileges BEFORE calling this function.
    try:
        with open_source(path, os.geteuid()) as incoming:
            if os.fstat(incoming.fileno()).st_size > MAX_INPUT:
                raise CertificateError("SSH input exceeds the 1 MiB limit")
            data = incoming.read(MAX_INPUT + 1)
    except (FileNotFoundError, PermissionError) as error:
        raise MissingInput("SSH input is missing or inaccessible") from error
    if len(data) > MAX_INPUT:
        raise CertificateError("SSH input exceeds the 1 MiB limit")
    return data


def worker_command(*arguments):
    # Only the immutable packaged library is added to isolated Python's path.
    entry = (f"import sys; sys.path.insert(0, {str(Path(__file__).resolve().parent)!r}); "
             "from ssh_certificate import main; sys.exit(main())")
    return [sys.executable, "-I", "-c", entry, *arguments]


def run_child(command, *, capture=False, timeout=30):
    environment = os.environ | {"SSH_ASKPASS_REQUIRE": "never", "LC_ALL": "C", "TZ": "UTC"}
    child = subprocess.Popen(command, stdin=subprocess.DEVNULL,
                             stdout=subprocess.PIPE if capture else subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL, env=environment, start_new_session=True)
    try:
        output, _ = child.communicate(timeout=timeout)
        return child.returncode, output
    finally:
        # Also handles the overall deadline, SIGTERM and KeyboardInterrupt.
        if child.poll() is None:
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            child.wait()


def read_user_key(path, user, group):
    status, data = run_child(worker_command("read-user-key", "--user", user, "--group", group,
                                          "--public-key", path), capture=True)
    if status == 3:
        raise MissingInput("SSH public key is missing or inaccessible to its recipient")
    if status:
        raise CertificateError("SSH public-key reader refused the input (requires a readable regular file of at most 1 MiB)")
    if len(data) > MAX_INPUT:
        raise CertificateError("SSH public key exceeds the 1 MiB limit")
    return data


def public_key(data):
    # Restrict files to one key; do not ignore a second record or accept a cert
    # as the supposedly unsigned public key. Comments stay harmless data.
    if not data.strip() or len(data.splitlines()) != 1:
        raise CertificateError("Expected one SSH public key")
    if data.split()[0].startswith(b"sk-"):
        # cryptography can load a security-key public key but discards its
        # application binding when serializing it. Never silently sign a
        # different, non-security-key identity.
        raise CertificateError("Security-key certificates require an external signer; supported keys are RSA, ECDSA and Ed25519")
    key = load_ssh_public_identity(data)
    if isinstance(key, SSHCertificate):
        raise CertificateError("Expected an unsigned SSH public key")
    return key.public_bytes(Encoding.OpenSSH, PublicFormat.OpenSSH)


def validate_certificate(data, key, kind, principals, now=None):
    if len(data.splitlines()) != 1:
        raise CertificateError("Expected one SSH certificate")
    certificate = load_ssh_public_identity(data)
    expected_type = SSHCertificateType.HOST if kind == "host" else SSHCertificateType.USER
    if not isinstance(certificate, SSHCertificate) or certificate.type != expected_type:
        raise CertificateError("Wrong SSH certificate type")
    certificate.verify_cert_signature()
    if certificate.public_key().public_bytes(Encoding.OpenSSH, PublicFormat.OpenSSH) != public_key(key):
        raise CertificateError("SSH certificate does not match the configured public key")
    now = time.time() if now is None else now
    if not certificate.valid_after <= now < certificate.valid_before:
        raise CertificateError("SSH certificate is expired or not yet valid")
    if not set(value.encode() for value in principals).issubset(certificate.valid_principals):
        raise CertificateError("SSH certificate is missing configured principals")


def prepare(args):
    principals = json.loads(args.principals)
    if not isinstance(principals, list) or not principals or any(
            not isinstance(value, str) or not value or "," in value or
            any(ord(char) < 32 or ord(char) == 127 for char in value) for value in principals):
        raise CertificateError("Invalid SSH certificate principals")
    try:
        source = read_bounded(args.source_file or args.ca_key)
        key = (read_user_key(args.public_key, args.user, args.group) if args.command == "user"
               else read_bounded(args.public_key))
        key = public_key(key) + b"\n"
    except MissingInput:
        if args.command == "user" and not args.required:
            print(f"warning: SSH signing input for {args.name} is unavailable; skipping cert signing")
            return
        raise

    os.umask(0o077)
    with tempfile.TemporaryDirectory(prefix="nixi-ssh-cert-", dir=args.runtime_directory) as directory:
        root = Path(directory)
        if args.source_file:
            certificate = source
        else:
            ca = root / "ca"
            ca.write_bytes(source)
            key_path = root / "key.pub"
            key_path.write_bytes(key)
            status, _ = run_child([args.ssh_keygen, "-q", *( ["-h"] if args.command == "host" else []),
                                   "-s", str(ca), "-I", args.identity + "-" + time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()),
                                   "-n", ",".join(principals), "-V", args.validity,
                                   "-z", str(time.time_ns()), str(key_path)])
            if status:
                raise CertificateError("SSH signing failed (CA must be usable noninteractively)")
            certificate = read_bounded(root / "key-cert.pub")
        validate_certificate(certificate, key, args.command, principals)
        if args.command == "host":
            # Root destinations have a protected no-follow parent walk. No
            # unchecked input is ever written to the live certificate path.
            directory_fd = root_destination(args.certificate)
            try:
                replace_file(io.BytesIO(certificate), directory_fd, Path(args.certificate).name, 0o644)
            finally:
                os.close(directory_fd)
        else:
            staged = root / "validated-cert.pub"
            staged.write_bytes(certificate)
            status, _ = run_child(worker_command("install-user-cert", "--source-file", str(staged),
                                                "--certificate", args.certificate,
                                                "--user", args.user, "--group", args.group))
            if status:
                raise CertificateError("SSH certificate installation failed; check recipient/destination permissions")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ssh-keygen", default="ssh-keygen")
    parser.add_argument("command", choices=["user", "host", "read-user-key", "install-user-cert"])
    parser.add_argument("--public-key")
    parser.add_argument("--certificate")
    parser.add_argument("--user")
    parser.add_argument("--group")
    sources = parser.add_mutually_exclusive_group()
    sources.add_argument("--source-file")
    sources.add_argument("--ca-key")
    parser.add_argument("--principals", default="[]")
    parser.add_argument("--identity", default="nixi")
    parser.add_argument("--name", default="certificate")
    parser.add_argument("--validity", default="+30d")
    parser.add_argument("--required", action="store_true")
    parser.add_argument("--timeout", type=int, default=45)
    parser.add_argument("--runtime-directory", default="/private/var/root" if sys.platform == "darwin" else "/run")
    args = parser.parse_args(argv)
    if args.timeout < 1:
        parser.error("timeout must be positive")
    required = {"read-user-key": ["public_key", "user", "group"],
                "install-user-cert": ["source_file", "certificate", "user", "group"],
                "user": ["public_key", "certificate", "ca_key", "user", "group"],
                "host": ["public_key", "certificate"]}[args.command]
    if any(not getattr(args, name) for name in required) or (args.command == "host" and not (args.source_file or args.ca_key)):
        parser.error("missing certificate operation arguments")
    def deadline(_signum, _frame):
        raise TimeoutError("SSH certificate operation exceeded its deadline")
    def interrupted(signum, _frame):
        raise SystemExit(128 + signum)
    previous = {sig: signal.getsignal(sig) for sig in (signal.SIGALRM, signal.SIGTERM, signal.SIGHUP)}
    signal.signal(signal.SIGALRM, deadline)
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGHUP, interrupted)
    signal.alarm(args.timeout)
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    try:
        if args.command == "read-user-key":
            drop_privileges(args.user, args.group)
            sys.stdout.buffer.write(read_bounded(args.public_key))
        elif args.command == "install-user-cert":
            install(args.source_file, args.certificate, args.user, args.group, 0o644)
        else:
            prepare(args)
        return 0
    except MissingInput as error:
        print(str(error), file=sys.stderr)
        return 3
    except (OSError, ValueError, KeyError, InvalidSignature, UnsupportedAlgorithm, subprocess.TimeoutExpired) as error:
        # Never expose key bytes or external-tool output in activation logs.
        detail = str(error) if isinstance(error, CertificateError) else type(error).__name__
        print(f"SSH certificate operation failed: {detail}", file=sys.stderr)
        return 1
    finally:
        signal.alarm(0)
        for sig, handler in previous.items():
            signal.signal(sig, handler)


if __name__ == "__main__":
    sys.exit(main())
