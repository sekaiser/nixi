#!/usr/bin/env python3
"""Test-only runner: serial CLI tests in resource-bounded process groups."""
import argparse
import math
import os
import resource
import select
import struct
import subprocess
import sys
import time
import unittest

from test_cli import ConsumerCLI


def run_isolated(command, timeout=60, output_limit=2 * 1024 * 1024, *, env=None, cwd=None):
    if not math.isfinite(timeout) or timeout <= 0:
        raise ValueError("timeout must be finite and positive")
    if type(output_limit) is not int or not 0 < output_limit <= 2**31 - 1:
        raise ValueError("output_limit must be a positive 32-bit integer")
    helper = os.environ.get("HEY_PROCESS_SUPERVISOR", "nixi-process-supervisor")
    # Only the native supervisor signals the job's process group. It keeps the
    # leader waitable until the final signal, so its PGID cannot be recycled.
    process = subprocess.Popen(
        [helper, "--limit", str(output_limit), "--timeout", str(timeout), "--", *command],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env, cwd=cwd)
    output = bytearray()
    deadline = time.monotonic() + timeout + 4  # includes bounded native cleanup

    def read_exact(size):
        data = bytearray()
        while len(data) < size:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([process.stdout], [], [], remaining)[0]:
                raise RuntimeError("test supervisor deadline exceeded")
            chunk = os.read(process.stdout.fileno(), size - len(data))
            if not chunk:
                raise RuntimeError("test supervisor ended without a complete result")
            data.extend(chunk)
        return data

    status, failure = 1, None
    try:
        if read_exact(6) != b"NXSP1\n":
            raise RuntimeError("invalid test supervisor protocol")
        while True:
            tag, size = struct.unpack(">cI", read_exact(5))
            if size > 65536 or size == 0:
                raise RuntimeError("invalid test supervisor frame")
            payload = read_exact(size)
            if tag in (b"O", b"E"):
                available = output_limit - len(output)
                output.extend(payload[:available])
                if size > available:
                    raise RuntimeError("test output limit exceeded")
            elif tag == b"R":
                fields = payload.split()
                if len(fields) != 3 or not all(field.isdigit() for field in fields):
                    raise RuntimeError("invalid test supervisor result")
                status, reason, error_number = map(int, fields)
                if not (0 <= status <= 255 and 0 <= reason <= 5 and error_number >= 0):
                    raise RuntimeError("invalid test supervisor result")
                failure = {0: None, 1: "test deadline exceeded",
                           2: "test output limit exceeded"}.get(reason, "test supervision failed")
                if process.wait(timeout=max(0.01, deadline - time.monotonic())) != 0:
                    raise RuntimeError("test supervisor failed during cleanup")
                break
            else:
                raise RuntimeError("invalid test supervisor frame type")
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        failure = str(error)
    finally:
        # Keep this lifetime pipe open during capture; EOF cancels the job even
        # when Python itself crashes. Never killpg from a reaped Popen PID.
        process.stdin.close()
        try:
            process.wait(timeout=4)
        except subprocess.TimeoutExpired:
            process.kill()  # last resort: the helper itself, not a cached PGID
            process.wait(timeout=1)
            failure = "test supervisor did not finish cleanup"
        finally:
            process.stdout.close()
    return status if failure is None else 1, output.decode("utf-8", errors="replace"), failure


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("tests", nargs="*")
    parser.add_argument("--worker", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    names = args.tests or unittest.defaultTestLoader.getTestCaseNames(ConsumerCLI)
    names = [name.removeprefix("ConsumerCLI.") for name in names]
    if args.worker:
        soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
        resource.setrlimit(resource.RLIMIT_NOFILE, (min(soft, 256), hard))
        suite = unittest.TestSuite(ConsumerCLI(name) for name in names)
        return 0 if unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful() else 1
    for name in names:
        status, output, failure = run_isolated([sys.executable, __file__, "--worker", name])
        print(output, end="", flush=True)
        if failure:
            print(f"{name}: {failure}", file=sys.stderr)
        # Stop on first failure rather than escalating host resource pressure.
        if status:
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
