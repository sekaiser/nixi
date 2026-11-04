"""Installer regressions; never require root or use real secret files."""
import grp
import os
from pathlib import Path
import pwd
import stat
import sys
import tempfile
from contextlib import contextmanager
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from fixture_ancestry import model_ancestor_fstat

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import install_user_file as installer


class UserFileInstallation(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="nixi-user-file-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        ancestry = model_ancestor_fstat(self.root)
        ancestry.__enter__()
        self.addCleanup(ancestry.__exit__, None, None, None)
        self.source = self.root / "source"
        self.source.write_text("synthetic secret\n")
        self.user = pwd.getpwuid(os.geteuid()).pw_name
        self.group = grp.getgrgid(os.getegid()).gr_name

    def install(self, target, mode=0o600):
        # Tests already run as the recipient. Avoid changing the test process's
        # umask (the production helper is always a separate process).
        with patch.object(installer.os, "umask"):
            installer.install(self.source, target, self.user, self.group, mode)

    def test_atomic_install_and_permissions(self):
        target = self.root / "home/config/secret"
        self.install(target)
        self.assertEqual(target.read_text(), self.source.read_text())
        self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(target.parent.stat().st_mode), 0o700)
        self.assertEqual(list(target.parent.iterdir()), [target])

    def test_opt_in_tracking_creates_private_receipt(self):
        target = self.root / "home/config/secret"
        receipt = self.root / "state/receipt.json"
        with patch.object(installer.os, "umask"):
            installer.install(self.source, target, self.user, self.group, 0o600, receipt=receipt)
        self.assertTrue(receipt.is_file())
        self.assertEqual(stat.S_IMODE(receipt.stat().st_mode), 0o600)
        self.assertNotIn(b"synthetic secret", receipt.read_bytes())

    def test_oversize_source_preserves_destination_and_cleans_staging(self):
        target = self.root / "installed"
        target.write_text("previous")
        self.source.write_bytes(b"x" * (1024 * 1024 + 1))
        with self.assertRaises(ValueError):
            self.install(target)
        self.assertEqual(target.read_text(), "previous")
        self.assertEqual(list(self.root.glob(".nixi-install-*")), [])

    def test_destination_symlink_replaced_not_followed(self):
        outside = self.root / "outside"
        outside.write_text("do not overwrite\n")
        target = self.root / "home/certificate"
        target.parent.mkdir()
        target.symlink_to(outside)
        self.install(target, 0o644)
        self.assertFalse(target.is_symlink())
        self.assertEqual(outside.read_text(), "do not overwrite\n")
        self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o644)

    def test_existing_directory_permissions_preserved(self):
        parent = self.root / "shared-readonly"
        parent.mkdir(mode=0o750)
        for mode in (0o600, 0o644):
            self.install(parent / "installed", mode)
            self.assertEqual(stat.S_IMODE(parent.stat().st_mode), 0o750)
            self.assertEqual(stat.S_IMODE((parent / "installed").stat().st_mode), mode)

    def test_writable_directory_rejected_without_chmod(self):
        parent = self.root / "unsafe"
        parent.mkdir()
        parent.chmod(0o770)
        with self.assertRaises(PermissionError):
            self.install(parent / "secret")
        self.assertEqual(stat.S_IMODE(parent.stat().st_mode), 0o770)
        self.assertEqual(list(parent.iterdir()), [])

    def test_parent_symlink_rejected(self):
        parent = self.root / "actual"
        parent.mkdir(mode=0o750)
        link = self.root / "link"
        link.symlink_to(parent, target_is_directory=True)
        with self.assertRaises(OSError):
            self.install(link / "secret")
        self.assertEqual(list(parent.iterdir()), [])
        self.assertEqual(stat.S_IMODE(parent.stat().st_mode), 0o750)

    def test_parent_rename_cannot_redirect_replacement(self):
        parent = self.root / "parent"
        parent.mkdir(mode=0o750)
        moved = self.root / "moved"
        replace = os.replace
        def move_parent(*args, **kwargs):
            parent.rename(moved)
            parent.mkdir()
            return replace(*args, **kwargs)
        with patch.object(installer.os, "replace", side_effect=move_parent):
            self.install(parent / "secret")
        self.assertEqual((moved / "secret").read_text(), self.source.read_text())
        self.assertEqual(list(parent.iterdir()), [])

    def test_temporary_collision_does_not_delete_existing_file(self):
        parent = self.root / "parent"
        parent.mkdir()
        existing = parent / ".nixi-install-fixed"
        existing.write_text("preserve")
        with patch.object(installer.secrets, "token_hex", return_value="fixed"):
            with self.assertRaises(FileExistsError):
                self.install(parent / "secret")
        self.assertEqual(existing.read_text(), "preserve")

    def test_no_destination_access_before_privilege_drop(self):
        protected = self.root / "protected"
        protected.mkdir(mode=0o755)
        before = protected.stat().st_mode
        link = self.root / "home"
        link.symlink_to(protected, target_is_directory=True)
        with patch.object(installer, "drop_privileges", side_effect=PermissionError("fixture")):
            with self.assertRaises(PermissionError):
                self.install(link / "secret")
        self.assertEqual(protected.stat().st_mode, before)
        self.assertEqual(list(protected.iterdir()), [])

    def test_privileges_drop_in_order(self):
        events = []
        with (patch.object(installer.pwd, "getpwnam", return_value=SimpleNamespace(pw_uid=1234)),
              patch.object(installer.grp, "getgrnam", return_value=SimpleNamespace(gr_gid=5678)),
              patch.object(installer.os, "geteuid", side_effect=[0, 1234]),
              patch.object(installer.os, "getegid", return_value=5678),
              patch.object(installer.os, "initgroups", side_effect=lambda *args: events.append(("groups", args))),
              patch.object(installer.os, "setgid", side_effect=lambda gid: events.append(("gid", gid))),
              patch.object(installer.os, "setuid", side_effect=lambda uid: events.append(("uid", uid)))):
            installer.drop_privileges("alice", "users")
        self.assertEqual(events, [("groups", ("alice", 5678)), ("gid", 5678), ("uid", 1234)])

    @contextmanager
    def privileged_source(self, source):
        # Exercise the real descriptor walk in a synthetic filesystem root.
        # Simulate root directory ownership only; permissions are still checked.
        check = installer._check_source_directory
        root_fd = os.open(self.root, os.O_RDONLY | os.O_DIRECTORY)
        try:
            with patch.object(installer, "_check_source_directory", side_effect=lambda info:
                              check(SimpleNamespace(st_uid=0, st_mode=info.st_mode))):
                fd = installer._open_privileged_source(root_fd, source, os.geteuid())
            with os.fdopen(fd, "rb") as incoming:
                yield incoming
        finally:
            os.close(root_fd)

    def test_source_trust_permissions_and_ownership(self):
        for uid, mode in ((1001, 0o755), (0, 0o777), (0, 0o1777), (0, 0o775)):
            with self.assertRaises(PermissionError):
                installer._check_source_directory(SimpleNamespace(st_uid=uid, st_mode=stat.S_IFDIR | mode))
        installer._check_source_directory(SimpleNamespace(st_uid=0, st_mode=stat.S_IFDIR | 0o755))
        for uid, mode in ((999, 0o600), (0, 0o666), (1234, 0o660)):
            with self.assertRaises(PermissionError):
                installer._check_source_file(SimpleNamespace(st_uid=uid, st_mode=stat.S_IFREG | mode), 1234)
        for uid in (0, 1234):
            installer._check_source_file(SimpleNamespace(st_uid=uid, st_mode=stat.S_IFREG | 0o640), 1234)

    def test_managed_source_symlinks_and_parent_links(self):
        generation = self.root / "generations/1"
        generation.mkdir(parents=True)
        (generation / "secret").write_text("generation one")
        (self.root / "secrets").symlink_to("generations/1", target_is_directory=True)
        (self.root / "absolute").symlink_to("/generations/1/secret")
        (self.root / "links").mkdir()
        (self.root / "links/relative").symlink_to("../generations/1/secret")
        for source in ("/secrets/secret", "/absolute", "/links/relative"):
            with self.privileged_source(source) as incoming:
                self.assertEqual(incoming.read(), b"generation one")

    def test_privileged_source_rejects_writable_parent(self):
        parent = self.root / "untrusted"
        parent.mkdir()
        parent.chmod(0o777)
        (parent / "secret").write_text("not trusted")
        (self.root / "link").symlink_to("untrusted/secret")
        with self.assertRaises(PermissionError):
            with self.privileged_source("/link"):
                self.fail("Untrusted parent accepted")

    def test_source_special_files_and_symlink_loops_are_rejected(self):
        os.mkfifo(self.root / "fifo")
        (self.root / "loop").symlink_to("loop")
        (self.root / "fifo-link").symlink_to("fifo")
        for source in ("/fifo", "/fifo-link", "/loop", "/"):
            with self.assertRaises(ValueError):
                with self.privileged_source(source):
                    self.fail("Invalid source accepted")
        existing = self.root / "installed"
        existing.write_text("preserve")
        self.source = self.root / "fifo"
        with self.assertRaises(ValueError):
            self.install(existing)
        self.assertEqual(existing.read_text(), "preserve")

    def test_source_swap_to_symlink_cannot_redirect_open(self):
        other = self.root / "other"
        other.write_text("not requested")
        original = os.open
        def swap(path, flags, *args, **kwargs):
            if path == "source" and "dir_fd" in kwargs:
                self.source.unlink()
                self.source.symlink_to(other)
            return original(path, flags, *args, **kwargs)
        with patch.object(installer.os, "open", side_effect=swap):
            with self.assertRaises(OSError):
                with self.privileged_source("/source"):
                    self.fail("Source redirection accepted")

    def test_source_parent_descriptor_survives_provider_rotation(self):
        parent = self.root / "generation"
        parent.mkdir()
        (parent / "secret").write_text("original")
        original = os.open
        def rotate(path, flags, *args, **kwargs):
            fd = original(path, flags, *args, **kwargs)
            if path == "generation" and "dir_fd" in kwargs:
                parent.rename(self.root / "old-generation")
                parent.mkdir()
                (parent / "secret").write_text("replacement")
            return fd
        with patch.object(installer.os, "open", side_effect=rotate):
            with self.privileged_source("/generation/secret") as incoming:
                self.assertEqual(incoming.read(), b"original")

    def test_source_file_replacement_between_stat_and_open_is_rejected(self):
        original = os.open
        def replace(path, flags, *args, **kwargs):
            if path == "source" and "dir_fd" in kwargs:
                self.source.rename(self.root / "original-source")
                self.source.write_text("replacement")
            return original(path, flags, *args, **kwargs)
        with patch.object(installer.os, "open", side_effect=replace):
            with self.assertRaisesRegex(ValueError, "Source changed"):
                with self.privileged_source("/source"):
                    self.fail("Source replacement accepted")

    def test_root_dispatch_uses_filesystem_root_and_checked_walker(self):
        seen = []
        def opened(root_fd, source, recipient_uid):
            root_info = os.fstat(root_fd)
            actual_root = os.stat("/")
            self.assertEqual((root_info.st_dev, root_info.st_ino), (actual_root.st_dev, actual_root.st_ino))
            seen.append((source, recipient_uid))
            return os.open(self.source, os.O_RDONLY)
        uid = os.geteuid()
        with (patch.object(installer.os, "geteuid", return_value=0),
              patch.object(installer, "_open_privileged_source", side_effect=opened)):
            with installer.open_source(self.source, uid) as incoming:
                self.assertEqual(incoming.read(), b"synthetic secret\n")
        self.assertEqual(seen, [(str(self.source), uid)])

    def test_relative_source_is_rejected_before_destination_access(self):
        with self.assertRaises(ValueError):
            installer.open_source("relative-source", os.geteuid())

    def test_unprivileged_source_can_use_user_owned_symlinks(self):
        link = self.root / "link"
        link.symlink_to(self.source)
        with installer.open_source(link, os.geteuid()) as incoming:
            self.assertEqual(incoming.read(), b"synthetic secret\n")

    def test_root_destination_walk_rejects_symlink_and_writable_ancestors(self):
        (self.root / "protected").mkdir()
        (self.root / "unsafe").mkdir()
        (self.root / "unsafe").chmod(0o777)
        (self.root / "alias").symlink_to("protected", target_is_directory=True)
        original_open = os.open
        check = installer._check_source_directory
        def opened(path, *args, **kwargs):
            return original_open(self.root if path == "/" else path, *args, **kwargs)
        with (patch.object(installer.os, "geteuid", return_value=0),
              patch.object(installer.os, "open", side_effect=opened),
              patch.object(installer, "_check_source_directory", side_effect=lambda info:
                           check(SimpleNamespace(st_uid=0, st_mode=info.st_mode)))):
            fd = installer.root_destination("/protected/new/cert")
            os.close(fd)
            self.assertTrue((self.root / "protected/new").is_dir())
            for target in ("/unsafe/new/cert", "/alias/new/cert"):
                with self.assertRaises(OSError):
                    installer.root_destination(target)
            self.assertFalse((self.root / "unsafe/new").exists())

    def test_host_destination_requires_canonical_absolute_path(self):
        for path in ("relative", "/", "/a/../b", "/a//b", "/a/./b"):
            with self.assertRaises(ValueError):
                installer.root_destination(path)

    def test_provider_directory_preflight_reuses_protected_walk(self):
        original_open = os.open
        check = installer._check_source_directory
        def opened(path, *args, **kwargs):
            return original_open(self.root if path == "/" else path, *args, **kwargs)
        with (patch.object(installer.os, "geteuid", return_value=0),
              patch.object(installer.os, "open", side_effect=opened),
              patch.object(installer, "_check_source_directory", side_effect=lambda info:
                           check(SimpleNamespace(st_uid=0, st_mode=info.st_mode)))):
            with patch.object(sys, "argv", ["installer", "--prepare-source-directory", "/protected/mount"]):
                installer.main()
            self.assertEqual(list((self.root / "protected/mount").iterdir()), [])
            (self.root / "unsafe").mkdir()
            (self.root / "unsafe").chmod(0o775)
            (self.root / "link").symlink_to("protected")
            for directory in ("/unsafe/mount", "/link/mount", "/protected/../other"):
                with patch.object(sys, "argv", ["installer", "--prepare-source-directory", directory]):
                    with self.assertRaises((ValueError, OSError)):
                        installer.main()
            self.assertEqual(stat.S_IMODE((self.root / "unsafe").stat().st_mode), 0o775)
            self.assertFalse((self.root / "unsafe/mount").exists())

    def test_provider_preflight_requires_root_and_unambiguous_arguments(self):
        with (patch.object(installer.os, "geteuid", return_value=1234),
              patch.object(installer, "root_destination") as prepare,
              patch.object(sys, "stderr")):
            for arguments in (["--prepare-source-directory", "/protected"],
                              ["--prepare-source-directory", ""],
                              ["--prepare-source-directory", "/protected", "extra"], []):
                with patch.object(sys, "argv", ["installer", *arguments]):
                    with self.assertRaises(SystemExit):
                        installer.main()
            prepare.assert_not_called()


if __name__ == "__main__":
    unittest.main()
