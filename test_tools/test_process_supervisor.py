#!/usr/bin/env python3
"""Bounded, serial fixtures for the native capture lifecycle (no live services)."""
import json
import os
from pathlib import Path
import resource
import select
import signal
import struct
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
HELPER = os.environ.get("HEY_PROCESS_SUPERVISOR", "nixi-process-supervisor")


class Job:
    def __init__(self, command, *, limit=65536, timeout=2, inherit=False, cwd=None, env=None):
        self.errors = tempfile.TemporaryFile()
        self.process = subprocess.Popen(
            [HELPER, "--limit", str(limit), "--timeout", str(timeout),
             *(["--inherit-stderr"] if inherit else []), "--", *command],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.errors, cwd=cwd, env=env)

    def close(self):
        if not self.process.stdin.closed:
            self.process.stdin.close()
        try:
            self.process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            # Last-resort harness cleanup. Fixture descendants also self-expire.
            self.process.kill()
            self.process.wait(timeout=1)
            raise
        finally:
            self.process.stdout.close()
            self.errors.close()

    def result(self):
        data = bytearray()
        deadline = time.monotonic() + 4
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([self.process.stdout], [], [], remaining)[0]:
                raise AssertionError("supervisor did not finish within fixture deadline")
            chunk = os.read(self.process.stdout.fileno(), 65536)
            if not chunk:
                break
            data.extend(chunk)
            if len(data) > 2 * 1024 * 1024:
                raise AssertionError("fixture protocol output exceeded its safety cap")
        if self.process.wait(timeout=1) != 0:
            raise AssertionError("supervisor failed without delivering a result")
        if data[:6] != b"NXSP1\n":
            raise AssertionError("invalid protocol magic")
        position, outputs, result = 6, {b"O": b"", b"E": b""}, None
        while position < len(data):
            tag = bytes(data[position:position + 1])
            size, = struct.unpack(">I", data[position + 1:position + 5])
            position += 5
            payload = bytes(data[position:position + size])
            position += size
            if len(payload) != size or size > 65536 or result is not None:
                raise AssertionError("invalid protocol frame")
            if tag in outputs:
                outputs[tag] += payload
            elif tag == b"R":
                result = tuple(map(int, payload.split()))
            else:
                raise AssertionError("invalid protocol tag")
        if result is None:
            raise AssertionError("missing result frame")
        return outputs[b"O"], outputs[b"E"], result


class SupervisorTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="nixi-supervisor-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)

    def job(self, command, **kwargs):
        job = Job(command, **kwargs)
        self.addCleanup(job.close)
        return job

    def python(self, source, **kwargs):
        return self.job([sys.executable, "-c", source], **kwargs)

    def tree(self, mode="hang"):
        # Three generations, TERM-resistant but independently self-expiring.
        # PID files are synthetic test data; no system-wide descendant scans.
        return f'''import os, signal, time
from pathlib import Path
root = Path({str(self.root)!r})
signal.signal(signal.SIGTERM, signal.SIG_IGN)
role = 0
for generation in (1, 2):
    if os.fork(): break
    role = generation
signal.alarm(5)
(root / str(role)).write_text(str(os.getpid()))
while len(list(root.iterdir())) < 3: time.sleep(0.005)
if role == 0 and {mode!r} == "exit": os._exit(7)
if role == 0 and {mode!r} == "overflow": os.write(1, b"x" * 65537)
time.sleep(5)
'''

    def ready(self):
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            if len(list(self.root.iterdir())) == 3 and all(p.read_text() for p in self.root.iterdir()):
                return [int(p.read_text()) for p in self.root.iterdir()]
            time.sleep(0.01)
        self.fail("fixture tree did not start")

    def assert_gone(self, pids):
        # Linux containers may not reap orphan zombies promptly; a zombie has
        # already exited and holds no descriptors. Only the direct child is ours
        # to reap. Inspect exact fixture PIDs, never select kill targets.
        def alive(pid):
            try:
                os.kill(pid, 0)
                if sys.platform.startswith("linux"):
                    return Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[0] != "Z"
                return True
            except (ProcessLookupError, FileNotFoundError):
                return False

        deadline = time.monotonic() + 1
        remaining = pids
        while remaining and time.monotonic() < deadline:
            remaining = [pid for pid in remaining if alive(pid)]
            if remaining:
                time.sleep(0.02)
        self.assertEqual(remaining, [], "fixture descendants survived group cleanup")

    def test_output_argv_environment_cwd_stdin_and_status(self):
        arguments = ["a b", "$(not-a-shell)", "", "λ"]
        source = "import os,sys,json; print(json.dumps([sys.argv[1:],os.getcwd(),os.getenv('NX_FIXTURE'),sys.stdin.read()])); os.write(2,b'err\\x00\\xff'); sys.exit(7)"
        job = self.job([sys.executable, "-c", source, *arguments], cwd=self.root,
                       env=os.environ | {"NX_FIXTURE": "synthetic"})
        out, err, status = job.result()
        self.assertEqual(json.loads(out), [arguments, str(self.root.resolve()), "synthetic", ""])
        self.assertEqual(err, b"err\x00\xff")
        self.assertEqual(status, (7, 0, 0))

    def test_exact_limit_and_overflow_each_stream(self):
        for fd in (1, 2):
            for size in (65536, 65537):
                with self.subTest(fd=fd, size=size):
                    out, err, status = self.python(f"import os; os.write({fd}, b'x' * {size})").result()
                    self.assertEqual(status, (0, 0, 0) if size == 65536 else (125, 2, 0))
                    self.assertLessEqual(len(out), 65536)
                    self.assertLessEqual(len(err), 65536)
                    if size == 65536:
                        self.assertEqual(len(out if fd == 1 else err), size)

    def test_streamed_stderr_is_not_captured_or_limited(self):
        job = self.python("import os; os.write(2, b'x' * 70000); os.write(1, b'ok')", inherit=True)
        self.assertEqual(job.result(), (b"ok", b"", (0, 0, 0)))
        self.assertEqual(os.fstat(job.errors.fileno()).st_size, 70000)

    def test_both_streams_and_signal_exit(self):
        out, err, status = self.python("import os; [(os.write(1,b'o'*4096), os.write(2,b'e'*4096)) for _ in range(16)]").result()
        self.assertEqual((out, err, status), (b"o" * 65536, b"e" * 65536, (0, 0, 0)))
        self.assertEqual(self.python("import os,signal; os.kill(os.getpid(),signal.SIGTERM)").result()[2],
                         (128 + signal.SIGTERM, 0, 0))

    def test_immediate_control_close_is_bounded(self):
        job = self.python("raise SystemExit(0)")
        job.process.stdin.close()
        # Cancellation may arrive before or just after fork; either must exit
        # promptly without requiring the receiver to drain the protocol.
        self.assertIn(job.process.wait(timeout=2), (0, 125))

    def test_detached_pipe_holder_is_reported_not_silently_truncated(self):
        source = '''import os, signal, time
ready, writer = os.pipe()
pid = os.fork()
if pid == 0:
    os.close(ready)
    os.setsid()
    signal.alarm(1)
    os.write(writer, b"ready")
    time.sleep(1)
    os._exit(0)
os.close(writer)
os.read(ready, 5)
os._exit(0)
'''
        self.assertEqual(self.python(source).result()[2][:2], (125, 5))

    def test_exit_status_is_distinct_from_supervisor_failure(self):
        for status in (0, 124, 125, 127):
            self.assertEqual(self.python(f"raise SystemExit({status})").result()[2], (status, 0, 0))
        self.assertEqual(self.job([str(self.root / "missing")]).result()[2], (127, 4, 2))

    def test_timeout_kills_term_resistant_descendants(self):
        job = self.python(self.tree(), timeout=0.4)
        pids = self.ready()
        self.assertEqual(job.result()[2], (124, 1, 0))
        self.assert_gone(pids)

    def test_exit_and_overflow_also_clean_descendants(self):
        for mode, status in (("exit", (7, 0, 0)), ("overflow", (125, 2, 0))):
            job = self.python(self.tree(mode))
            pids = self.ready()
            self.assertEqual(job.result()[2], status)
            self.assert_gone(pids)
            for path in self.root.iterdir():
                path.unlink()

    def test_control_eof_and_broken_reader_cancel_without_deadline(self):
        for mode in ("control", "reader"):
            job = self.python(self.tree("overflow"), timeout=0, limit=1024 * 1024)
            pids = self.ready()
            (job.process.stdin if mode == "control" else job.process.stdout).close()
            job.process.wait(timeout=2)
            self.assert_gone(pids)
            for path in self.root.iterdir():
                path.unlink()

    def test_stalled_reader_still_obeys_timeout(self):
        job = self.python("import os,signal; signal.alarm(5); os.write(1,b'x'*1048576)",
                          timeout=0.2, limit=1048576)
        # Keep the output pipe open without draining it. Native buffer is fixed.
        job.process.wait(timeout=2)
        self.assertEqual(job.process.returncode, 125)

    @unittest.skipUnless(os.environ.get("JANET_PATH"), "Janet bridge environment not provided")
    def test_janet_death_cleans_tree_with_another_capture_alive(self):
        for death in (signal.SIGTERM, signal.SIGKILL):
            # Another supervisor remains alive across the victim's death. Its
            # exec must not inherit the victim's lifetime writer and delay EOF.
            env = os.environ | {"JANET_PATH": str(ROOT / "runtime") + os.pathsep + os.environ["JANET_PATH"]}
            source = f'''(import hey/subprocess)
(ev/spawn (subprocess/capture [{json.dumps(sys.executable)} "-c" {json.dumps(self.tree())}]))
(ev/sleep 0.15)
(subprocess/capture [{json.dumps(sys.executable)} "-c" "import time; time.sleep(5)"])
'''
            process = subprocess.Popen(["janet", "-e", source], env=env,
                                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            try:
                pids = self.ready()
                time.sleep(0.2)
                sibling = self.python("import time; time.sleep(2)", timeout=0)
                process.send_signal(death)
                _, errors = process.communicate(timeout=2)
                self.assertNotEqual(process.returncode, 0, errors)
                self.assert_gone(pids)
                self.assertIsNone(sibling.process.poll(), "unrelated capture was terminated")
                self.assertEqual(sibling.result()[2], (0, 0, 0))
            finally:
                if process.poll() is None:
                    process.kill()
                process.communicate(timeout=2)
            for path in self.root.iterdir():
                path.unlink()

    @unittest.skipUnless(os.environ.get("JANET_PATH"), "Janet bridge environment not provided")
    def test_janet_repeated_captures_under_low_fd_limit(self):
        env = os.environ | {"JANET_PATH": str(ROOT / "runtime") + os.pathsep + os.environ["JANET_PATH"]}
        source = f'''(import hey/subprocess)
(repeat 20 (assert (= 0 ((subprocess/capture [{json.dumps(sys.executable)} "-c" "pass"] 1) :status))))
'''
        # Apply the limit in a separate harness process, not this test runner.
        launcher = "import os,resource,sys; soft,hard=resource.getrlimit(resource.RLIMIT_NOFILE); resource.setrlimit(resource.RLIMIT_NOFILE,(min(soft,64),hard)); os.execvp('janet',['janet','-e',sys.argv[1]])"
        result = subprocess.run([sys.executable, "-c", launcher, source], env=env,
                                capture_output=True, text=True, timeout=8)
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    resource.setrlimit(resource.RLIMIT_NOFILE, (min(soft, 128), hard))
    unittest.main(verbosity=2, failfast=True)
