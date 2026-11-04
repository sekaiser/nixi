"""Explicit installed-copy retirement; disposable non-secret files, never root."""
import grp
import io
import json
import os
from pathlib import Path
import pwd
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from fixture_ancestry import actual_ancestry_trusted, model_ancestor_fstat

TOOLS = Path(__file__).resolve().parents[1] / "tools"
sys.path.insert(0, str(TOOLS))
import install_user_file as installer
import tracked_user_file as lifecycle


class TrackedFiles(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="nixi-retirement-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.actual_ancestry_trusted = actual_ancestry_trusted(self.root)
        ancestry = model_ancestor_fstat(self.root)
        ancestry.__enter__()
        self.addCleanup(ancestry.__exit__, None, None, None)
        self.source = self.root / "source"
        self.source.write_bytes(b"SYNTHETIC_PRIVATE_VALUE\n")
        self.target = self.root / "home/git/credential"
        self.receipt = self.root / "state/receipt.json"
        self.user = pwd.getpwuid(os.geteuid()).pw_name
        self.group = grp.getgrgid(os.getegid()).gr_name
        self.command = ([os.environ["NIXI_TEST_INSTALLER"]] if "NIXI_TEST_INSTALLER" in os.environ
                        else [sys.executable, str(TOOLS / "install_user_file.py")])

    def install(self):
        with patch.object(installer.os, "umask"):
            installer.install(self.source, self.target, self.user, self.group, 0o600, receipt=self.receipt)
        return lifecycle.preview(self.receipt)["reviewToken"]

    def pending(self):
        self.install()
        record = json.loads(self.receipt.read_text())
        holding = self.target.parent / lifecycle.quarantine(record)
        holding.mkdir(mode=0o700)
        self.target.rename(holding / "payload")
        return holding

    def cli(self, *args):
        return subprocess.run([*self.command, *map(str, args)], capture_output=True, text=True, timeout=5)

    def require_actual_cli_ancestry(self):
        if not self.actual_ancestry_trusted:
            self.skipTest("Actual host ancestry is untrusted; positive unmodified CLI acceptance requires the real-root guest")

    def test_ancestry_model_does_not_hide_an_unsafe_fixture_root(self):
        self.install()
        self.root.chmod(0o770)
        fd = os.open(self.root, os.O_RDONLY | os.O_DIRECTORY)
        try:
            actual = self.root.stat()
            observed = os.fstat(fd)
            self.assertEqual((observed.st_uid, observed.st_mode), (actual.st_uid, actual.st_mode))
            with self.assertRaises(PermissionError):
                lifecycle.preview(self.receipt)
        finally:
            os.close(fd)
            self.root.chmod(0o700)

    def test_unmodified_cli_refuses_untrusted_actual_ancestry(self):
        if self.actual_ancestry_trusted:
            self.skipTest("Actual host ancestry is trusted; unmapped-root rejection is exercised in the Linux sandbox")
        before = self.source.read_bytes()
        result = self.cli("--receipt", self.receipt, self.source, self.target, self.user, self.group, "0600")
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertNotIn("SYNTHETIC_PRIVATE_VALUE", result.stderr)
        self.assertFalse(self.receipt.exists())
        self.assertFalse(self.target.exists())
        self.assertEqual(self.source.read_bytes(), before)

    def test_preview_has_no_filesystem_writes_or_secret_fingerprints(self):
        token = self.install()
        before = {str(p): p.read_bytes() for p in self.root.rglob("*") if p.is_file()}
        with (patch.object(lifecycle.os, "mkdir", side_effect=AssertionError("preview wrote")),
              patch.object(lifecycle.os, "unlink", side_effect=AssertionError("preview unlinked"))):
            result = lifecycle.preview(self.receipt)
        self.assertEqual(result, {"status": "ready", "destination": str(self.target), "reviewToken": token})
        self.assertEqual(before, {str(p): p.read_bytes() for p in self.root.rglob("*") if p.is_file()})
        self.assertNotIn("sha256", json.dumps(result))
        self.assertNotIn("SYNTHETIC_PRIVATE_VALUE", self.receipt.read_text())
        for path in (self.receipt, self.receipt.with_name("receipt.json.lock")):
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            self.assertEqual(path.stat().st_uid, os.geteuid())

    def test_explicit_retirement_removes_only_the_recorded_copy(self):
        token = self.install()
        neighbor = self.target.parent / "unmanaged"
        neighbor.write_bytes(b"keep")
        receipt = self.receipt.read_bytes()
        self.assertEqual(lifecycle.retire(self.receipt, token)["status"], "retired")
        self.assertFalse(self.target.exists())
        self.assertEqual(neighbor.read_bytes(), b"keep")
        self.assertEqual(self.source.read_bytes(), b"SYNTHETIC_PRIVATE_VALUE\n")
        self.assertEqual(self.receipt.read_bytes(), receipt)
        self.assertEqual(list(self.target.parent.glob(".nixi-retire-*")), [])
        self.assertEqual(lifecycle.preview(self.receipt)["status"], "missing")
        self.assertEqual(lifecycle.retire(self.receipt, token)["status"], "missing")

    def test_untracked_files_are_never_adopted(self):
        self.target.parent.mkdir(parents=True)
        self.target.write_bytes(b"unknown")
        with self.assertRaises(OSError):
            lifecycle.preview(self.receipt)
        self.assertEqual(self.target.read_bytes(), b"unknown")
        self.assertFalse(self.receipt.parent.exists())

    def test_modified_file_is_preserved(self):
        token = self.install()
        self.target.write_bytes(b"user-changed")
        self.assertEqual(lifecycle.preview(self.receipt)["status"], "changed")
        with self.assertRaises(ValueError):
            lifecycle.retire(self.receipt, token)
        self.assertEqual(self.target.read_bytes(), b"user-changed")

    def test_identical_replacement_is_preserved(self):
        token = self.install()
        replacement = self.target.parent / "new"
        replacement.write_bytes(self.target.read_bytes())
        replacement.chmod(0o600)
        replacement.replace(self.target)
        self.assertEqual(lifecycle.preview(self.receipt)["status"], "changed")
        with self.assertRaises(ValueError):
            lifecycle.retire(self.receipt, token)

    def test_same_content_rewrite_and_restored_mtime_is_preserved(self):
        token = self.install()
        previous = self.target.stat()
        self.target.write_bytes(self.target.read_bytes())
        os.utime(self.target, ns=(previous.st_atime_ns, previous.st_mtime_ns))
        self.assertEqual(lifecycle.preview(self.receipt)["status"], "changed")
        with self.assertRaises(ValueError):
            lifecycle.retire(self.receipt, token)

    def test_mode_changes_and_hardlinks_are_preserved(self):
        token = self.install()
        self.target.chmod(0o644)
        self.assertEqual(lifecycle.preview(self.receipt)["status"], "unsafe")
        self.target.chmod(0o600)
        os.link(self.target, self.target.parent / "alias")
        self.assertEqual(lifecycle.preview(self.receipt)["status"], "unsafe")
        with self.assertRaises(ValueError):
            lifecycle.retire(self.receipt, token)
        self.assertTrue(self.target.exists())

    def test_foreign_ownership_is_rejected(self):
        self.install()
        real = lifecycle.os.stat
        def foreign(path, *args, **kwargs):
            info = real(path, *args, **kwargs)
            if path == self.target.name:
                values = list(info)
                values[4] = os.geteuid() + 1
                return os.stat_result(values)
            return info
        with patch.object(lifecycle.os, "stat", side_effect=foreign):
            self.assertEqual(lifecycle.preview(self.receipt)["status"], "unsafe")

    def test_symlinks_fifos_and_directories_are_not_retired(self):
        for kind in ("link", "fifo", "directory"):
            with self.subTest(kind=kind):
                token = self.install()
                self.target.unlink()
                if kind == "link":
                    self.target.symlink_to(self.source)
                elif kind == "fifo":
                    os.mkfifo(self.target, 0o600)
                else:
                    self.target.mkdir()
                self.assertEqual(lifecycle.preview(self.receipt)["status"], "unsafe")
                with self.assertRaises(ValueError):
                    lifecycle.retire(self.receipt, token)
                if kind == "directory":
                    self.target.rmdir()
                else:
                    self.target.unlink()
        self.assertEqual(self.source.read_bytes(), b"SYNTHETIC_PRIVATE_VALUE\n")

    def test_stale_review_token_after_reinstallation_is_rejected(self):
        old = self.install()
        new = self.install()
        self.assertNotEqual(old, new)
        with self.assertRaises(ValueError):
            lifecycle.retire(self.receipt, old)
        self.assertTrue(self.target.exists())

    def test_changed_file_between_validation_and_capture_is_restored(self):
        token = self.install()
        rename = lifecycle.os.rename
        def replace(*args, **kwargs):
            self.target.write_bytes(b"changed during capture")
            return rename(*args, **kwargs)
        with patch.object(lifecycle.os, "rename", side_effect=replace):
            with self.assertRaises(ValueError):
                lifecycle.retire(self.receipt, token)
        self.assertEqual(self.target.read_bytes(), b"changed during capture")
        self.assertEqual(list(self.target.parent.glob(".nixi-retire-*")), [])

    def test_new_target_appearing_after_capture_is_never_deleted(self):
        token = self.install()
        rename = lifecycle.os.rename
        def replace(*args, **kwargs):
            result = rename(*args, **kwargs)
            self.target.write_bytes(b"new independent file")
            return result
        with patch.object(lifecycle.os, "rename", side_effect=replace):
            lifecycle.retire(self.receipt, token)
        self.assertEqual(self.target.read_bytes(), b"new independent file")

    def test_handled_interruption_restores_captured_file(self):
        token = self.install()
        inspect = lifecycle.inspect_target
        def interrupt(*args, **kwargs):
            if kwargs.get("captured"):
                raise KeyboardInterrupt()
            return inspect(*args, **kwargs)
        with patch.object(lifecycle, "inspect_target", side_effect=interrupt):
            with self.assertRaises(KeyboardInterrupt):
                lifecycle.retire(self.receipt, token)
        self.assertEqual(self.target.read_bytes(), b"SYNTHETIC_PRIVATE_VALUE\n")

    def test_uncatchable_interruption_fixture_is_recoverable(self):
        holding = self.pending()
        self.assertEqual(lifecycle.preview(self.receipt)["status"], "pending")
        with self.assertRaises(ValueError):
            self.install()
        self.assertEqual(lifecycle.restore(self.receipt)["status"], "restored")
        self.assertEqual(self.target.read_bytes(), b"SYNTHETIC_PRIVATE_VALUE\n")
        self.assertFalse(holding.exists())

    def test_restore_never_overwrites_new_target(self):
        holding = self.pending()
        self.target.write_bytes(b"new file")
        with self.assertRaises(FileExistsError):
            lifecycle.restore(self.receipt)
        self.assertEqual(self.target.read_bytes(), b"new file")
        self.assertEqual((holding / "payload").read_bytes(), b"SYNTHETIC_PRIVATE_VALUE\n")

    def test_empty_interrupted_quarantine_can_be_resolved_explicitly(self):
        holding = self.pending()
        (holding / "payload").unlink()
        self.assertEqual(lifecycle.restore(self.receipt)["status"], "no-payload")
        self.assertFalse(holding.exists())

    def test_quarantine_with_unknown_files_is_preserved(self):
        holding = self.pending()
        (holding / "unknown").write_bytes(b"keep")
        with self.assertRaises(OSError):
            lifecycle.restore(self.receipt)
        self.assertEqual((holding / "unknown").read_bytes(), b"keep")
        self.assertTrue(self.target.exists())

    def test_receipt_symlinks_hardlinks_permissions_and_corruption_fail_closed(self):
        token = self.install()
        original = self.receipt.read_bytes()
        for data in (b'{"SYNTHETIC_PRIVATE_VALUE":', b'[]', b'{"version":1,"version":1}'):
            self.receipt.write_bytes(data)
            with self.assertRaises(ValueError):
                lifecycle.preview(self.receipt)
        self.receipt.write_bytes(original)
        self.receipt.chmod(0o644)
        with self.assertRaises(PermissionError):
            lifecycle.preview(self.receipt)
        self.receipt.chmod(0o600)
        os.link(self.receipt, self.root / "receipt-alias")
        with self.assertRaises(PermissionError):
            lifecycle.retire(self.receipt, token)
        (self.root / "receipt-alias").unlink()
        self.receipt.unlink()
        self.receipt.symlink_to(self.source)
        with self.assertRaises(PermissionError):
            lifecycle.preview(self.receipt)
        self.assertTrue(self.target.exists())

    def test_receipt_cannot_be_reused_for_another_target(self):
        self.install()
        other = self.root / "other"
        with patch.object(installer.os, "umask"):
            with self.assertRaises(ValueError):
                installer.install(self.source, other, self.user, self.group, 0o600, receipt=self.receipt)
        self.assertFalse(other.exists())

    def test_interrupted_receipt_write_does_not_authorize_deletion(self):
        old = self.install()
        replace = installer.replace_file
        def fail(incoming, directory, name, mode):
            if name == self.receipt.name:
                raise OSError("synthetic interruption")
            return replace(incoming, directory, name, mode)
        with (patch.object(installer, "replace_file", side_effect=fail), patch.object(installer.os, "umask")):
            with self.assertRaises(OSError):
                installer.install(self.source, self.target, self.user, self.group, 0o600, receipt=self.receipt)
        self.assertEqual(lifecycle.preview(self.receipt)["status"], "changed")
        with self.assertRaises(ValueError):
            lifecycle.retire(self.receipt, old)

    def test_root_is_refused_before_any_path_access(self):
        with (patch.object(lifecycle.os, "geteuid", return_value=0), patch.object(lifecycle.os, "open") as opened):
            for action in (lambda: lifecycle.preview(self.receipt), lambda: lifecycle.retire(self.receipt, "token"),
                           lambda: lifecycle.restore(self.receipt)):
                with self.assertRaises(PermissionError):
                    action()
            opened.assert_not_called()

    def test_symlinked_or_writable_ancestors_are_refused(self):
        self.install()
        alias = self.root / "alias"
        alias.symlink_to(self.receipt.parent, target_is_directory=True)
        with self.assertRaises(OSError):
            lifecycle.preview(alias / self.receipt.name)
        self.receipt.parent.chmod(0o777)
        with self.assertRaises(PermissionError):
            lifecycle.preview(self.receipt)
        self.assertEqual(stat.S_IMODE(self.receipt.parent.stat().st_mode), 0o777)

    def test_invalid_paths_and_public_modes_are_rejected(self):
        for name in ("relative", "/", "/a/../b", "/a//b", "/a/./b", "/a\n", "/a\\b", "/nix/store/file"):
            with self.assertRaises(ValueError):
                lifecycle.canonical(name)
        with self.assertRaises(ValueError):
            lifecycle.install_tracked(io.BytesIO(b"data"), self.target, self.receipt, 0o644, installer.replace_file)
        self.assertFalse(self.target.exists())

    def test_cli_requires_apply_token_and_rejects_invalid_arguments(self):
        self.install()
        for args in (("--retire-receipt", self.receipt), ("--preview-retirement", self.receipt, "--review-token", "bad"),
                     ("--preview-retirement", self.receipt, "extra")):
            self.assertEqual(self.cli(*args).returncode, 2)

    def test_cli_redacts_invalid_receipts(self):
        self.require_actual_cli_ancestry()
        self.install()
        self.receipt.write_bytes(b'{"SYNTHETIC_PRIVATE_VALUE":')
        result = self.cli("--preview-retirement", self.receipt)
        self.assertEqual(result.returncode, 2)
        self.assertNotIn("SYNTHETIC_PRIVATE_VALUE", result.stdout + result.stderr)
        self.assertNotIn("Traceback", result.stderr)

    def test_cli_preview_and_explicit_apply(self):
        self.require_actual_cli_ancestry()
        token = self.install()
        result = self.cli("--preview-retirement", self.receipt)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["reviewToken"], token)
        self.assertTrue(self.target.exists())
        result = self.cli("--retire-receipt", self.receipt, "--review-token", token)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["status"], "retired")

    def test_packaged_cli_tracks_an_installation_with_literal_paths(self):
        self.require_actual_cli_ancestry()
        self.target = self.target.with_name("copy ' $(literal) with spaces")
        self.receipt = self.receipt.with_name("receipt ' $(literal).json")
        result = self.cli("--receipt", self.receipt, self.source, self.target, self.user, self.group, "0600")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.receipt.is_file())
        self.assertEqual(self.target.read_bytes(), b"SYNTHETIC_PRIVATE_VALUE\n")
        self.assertEqual(lifecycle.preview(self.receipt)["status"], "ready")

    def test_cooperating_operations_are_serialized_by_receipt_lock(self):
        self.require_actual_cli_ancestry()
        self.install()
        with lifecycle.locked(self.receipt):
            with self.assertRaises(subprocess.TimeoutExpired):
                subprocess.run([*self.command, "--preview-retirement", str(self.receipt)],
                               capture_output=True, timeout=0.2)
        self.assertEqual(self.cli("--preview-retirement", self.receipt).returncode, 0)


if __name__ == "__main__":
    unittest.main()
