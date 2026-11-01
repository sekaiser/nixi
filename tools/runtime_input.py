"""Bounded regular-file input; errors never include the input's contents."""
import argparse
from contextlib import contextmanager
import json
import os
import signal
import stat
import sys

SECRET_LIMIT = 64 * 1024
FILE_LIMIT = 1024 * 1024


def read_bounded(incoming, limit=FILE_LIMIT):
    data = incoming.read(limit + 1)
    if len(data) > limit:
        raise ValueError("Runtime input exceeds its size limit")
    return data


def read_regular(path, limit=FILE_LIMIT):
    # Provider symlinks are legitimate; validate the opened descriptor, not a
    # racy pathname stat. Nonblocking open prevents FIFOs from blocking first.
    fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode):
            raise ValueError("Runtime input must be a regular file")
        if info.st_size > limit:
            raise ValueError("Runtime input exceeds its size limit")
        with os.fdopen(fd, "rb", closefd=False) as incoming:
            return read_bounded(incoming, limit)
    finally:
        os.close(fd)


@contextmanager
def deadline(seconds):
    def expired(_signum, _frame):
        raise TimeoutError("Runtime input deadline exceeded")
    previous = signal.signal(signal.SIGALRM, expired)
    signal.alarm(seconds)
    try:
        yield
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, previous)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path")
    args = parser.parse_args()
    try:
        with deadline(5):
            value = read_regular(args.path, SECRET_LIMIT).decode("utf-8")
            # JSON preserves trailing spaces/newlines across the capture bridge.
            print(json.dumps(value))
        return 0
    except (OSError, ValueError):
        print("Credential input must be a readable UTF-8 regular file of at most 64 KiB; reads have a five-second deadline", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
