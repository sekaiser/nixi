"""Prepare a two-line OpenVPN credential file without exposing its values."""
import argparse
import os
from pathlib import Path
import sys
import tempfile
from runtime_input import SECRET_LIMIT, deadline, read_regular


def read_value(source, label):
    value = read_regular(source, SECRET_LIMIT)
    if value.endswith(b"\n"):
        value = value[:-1]
        if value.endswith(b"\r"):
            value = value[:-1]
    if not value or any(char in value for char in (b"\n", b"\r", b"\0")):
        raise ValueError(f"{label} must contain exactly one nonempty line")
    return value


def install(username_file, password_file, destination):
    # Validate both sources before touching the current credentials. Preserve
    # meaningful spaces and accept files with or without a final LF/CRLF.
    username = read_value(username_file, "username")
    password = read_value(password_file, "password")
    target = Path(destination)
    if target.parent.is_symlink() or not target.parent.is_dir():
        raise ValueError("credential directory must be an existing real directory")
    fd, temporary = tempfile.mkstemp(prefix=".auth-user-pass-", dir=target.parent)
    try:
        with os.fdopen(fd, "wb") as output:
            os.fchmod(output.fileno(), 0o400)
            output.write(username + b"\n" + password + b"\n")
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, target)
    finally:
        if os.path.lexists(temporary):
            os.unlink(temporary)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("username_file")
    parser.add_argument("password_file")
    parser.add_argument("destination")
    args = parser.parse_args()
    try:
        with deadline(5):
            install(args.username_file, args.password_file, args.destination)
    except (OSError, ValueError) as error:
        print(f"OpenVPN credentials could not be prepared ({type(error).__name__}); inputs must be readable regular files of at most 64 KiB, one nonempty line each", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
