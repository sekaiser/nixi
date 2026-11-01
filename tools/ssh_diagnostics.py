"""Read-only, bounded public SSH material checks; never execute SSH config."""
import argparse
import glob
import json
import os
from pathlib import Path
import re
import shlex
import sys
import time

from cryptography.hazmat.primitives.serialization import (
    SSHCertificate, SSHCertificateType, load_ssh_public_identity,
)
from runtime_input import FILE_LIMIT, deadline, read_regular


class Unverified(ValueError):
    """A static check cannot establish this connection-dependent policy."""


def optional_input(path):
    try:
        return read_regular(path)
    except FileNotFoundError:
        if os.path.lexists(path):
            raise ValueError("Dangling input")
        return None


def certificate(path, kind, now=None):
    data = optional_input(path)
    if data is None:
        return {"status": "absent"}
    if len(data.splitlines()) != 1:
        raise ValueError("Expected one certificate")
    cert = load_ssh_public_identity(data)
    expected = SSHCertificateType.USER if kind == "user" else SSHCertificateType.HOST
    if not isinstance(cert, SSHCertificate) or cert.type != expected:
        raise ValueError("Wrong certificate type")
    cert.verify_cert_signature()
    now = time.time() if now is None else now
    if not cert.valid_after <= now < cert.valid_before:
        raise ValueError("Certificate outside its validity interval")
    # This checks the embedded signature, not whether the issuer is trusted by
    # a remote server or whether its principals authorize a particular login.
    return {"status": "configured"}


def ca_entries(data):
    count = 0
    for line in data.decode("utf-8").splitlines():
        parts = line.split()
        if not parts or parts[0].startswith("#"):
            continue
        if parts[0] != "@cert-authority":
            continue
        if len(parts) < 4 or any(not pattern or pattern == "!" for pattern in parts[1].split(",")):
            raise ValueError("Malformed CA entry")
        key = load_ssh_public_identity(" ".join(parts[2:4]).encode())
        if isinstance(key, SSHCertificate):
            raise ValueError("CA must be a public key, not a certificate")
        count += 1
    if not count:
        raise ValueError("No CA entries")
    return count


def expanded_path(value, home, *, include=False):
    # No environment lookup or remote-host-dependent expansion in diagnostics.
    if "${" in value:
        raise Unverified()
    def token(match):
        if match[1] == "%":
            return "%"
        if match[1] == "d":
            return str(home)
        raise Unverified()
    value = re.sub(r"%(.|$)", token, value)
    if value.startswith("~/"):
        value = str(home / value[2:])
    elif value.startswith("~"):
        raise Unverified()
    if not os.path.isabs(value):
        if not include:
            raise Unverified()
        value = str(home / ".ssh" / value)
    return os.path.normpath(value)


def config_reference(config, target, home):
    """Conservative unconditional user-config check, not an SSH evaluator.

    Follow Includes in lexical order and honor first-value-wins. Host-specific
    trust settings/Includes, Match and dynamic paths require manual verification.
    Do not use ssh -G: Match exec may execute arbitrary configuration commands.
    """
    home = Path(home)
    files, total = 0, 0
    selected = None
    active = set()

    def visit(path, unconditional=True):
        nonlocal files, total, selected
        files += 1
        if files > 64 or len(active) >= 16:
            raise ValueError("SSH include limit exceeded")
        physical = Path(path).resolve()
        if physical in active:
            raise ValueError("Cyclic SSH Include")
        active.add(physical)
        try:
            data = read_regular(path)
            total += len(data)
            if total > FILE_LIMIT:
                raise ValueError("SSH config size limit exceeded")
            for line in data.decode("utf-8").splitlines():
                if not line.strip() or line.lstrip().startswith("#"):
                    continue
                match = re.fullmatch(r"[ \t]*([A-Za-z][A-Za-z0-9]*)(?:[ \t]+|[ \t]*=[ \t]*)(.*)", line)
                if not match:
                    raise ValueError("Malformed SSH directive")
                key, value = match[1].lower(), match[2]
                # whitespace before '=' may have been consumed by the regex.
                value = value.lstrip().removeprefix("=").lstrip()
                if key == "match":
                    raise Unverified()
                if key not in {"host", "include", "userknownhostsfile"}:
                    continue
                args = shlex.split(value, comments=True)
                if not args:
                    raise ValueError("Missing SSH directive arguments")
                if key == "host":
                    unconditional = args == ["*"]
                elif not unconditional:
                    raise Unverified()
                elif key == "include":
                    for pattern in args:
                        matches = []
                        for child in glob.iglob(expanded_path(pattern, home, include=True)):
                            matches.append(child)
                            if len(matches) + files > 64:
                                raise ValueError("SSH include limit exceeded")
                        for child in sorted(matches):
                            unconditional = visit(child, unconditional)
                elif selected is None:
                    selected = ([] if args == ["none"] else
                                [expanded_path(arg, home) for arg in args])
            return unconditional
        finally:
            active.remove(physical)

    visit(config)
    return os.path.normpath(target) in (selected or [])


def trust(path, config, home):
    data = optional_input(path)
    if data is None:
        return {"status": "absent"}
    count = ca_entries(data)
    try:
        referenced = config_reference(config, path, home)
    except Unverified:
        return {"status": "unverified"}
    return {"status": "configured" if referenced else "missing-reference", "count": count}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("kind", choices=["user", "host", "trust"])
    parser.add_argument("path")
    parser.add_argument("--config")
    parser.add_argument("--home")
    args = parser.parse_args()
    if args.kind == "trust" and (not args.config or not args.home):
        parser.error("trust requires --config and --home")
    try:
        with deadline(5):
            result = (trust(args.path, args.config, args.home) if args.kind == "trust"
                      else certificate(args.path, args.kind))
        print(json.dumps(result))
        return 0
    except Exception:
        # Parser/library exceptions may contain input. Do not forward them.
        print("SSH public material could not be validated within its input limits", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
