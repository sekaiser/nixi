"""Regression tests for the publication boundary; no network or private inputs."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("release", Path(__file__).resolve().parents[1] / "tools/release.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class PublicCommandSurfaceTests(unittest.TestCase):
    def test_core_entrypoints_are_regular_files(self):
        source = Path(__file__).resolve().parents[1]
        self.assertTrue((source / "bin/hey.d").is_dir())
        # Core entrypoints must exist; their presence does not imply that other
        # interactive scripts are unused. The release allowlist reviews every
        # exported file, and package checks constrain the installed executables.
        for name in ("hey", "hey.janet", "myip"):
            self.assertTrue((source / "bin" / name).is_file())
            self.assertFalse((source / "bin" / name).is_symlink())


class ReleaseTests(unittest.TestCase):
    def test_password_hashes_are_sensitive(self):
        import re
        for prefix in ("$y$", "$7$", "$6$", "$2b$"):
            value = prefix + "A" * 40
            self.assertIsNotNone(re.search(release.RULES["password hash"], value))

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / "source"
        self.root.mkdir()
        (self.root / "README.md").write_text("public\n")
        self.entries = [{"path": "README.md", "sha256": release.digest(self.root / "README.md"),
                         "executable": False}]
        self.manifest = {"version": 1, "files": self.entries}
        self.write_manifest()

    def write_manifest(self):
        (self.root / release.MANIFEST).write_text(json.dumps(self.manifest))

    def test_manifest_schema_is_closed(self):
        mutations = [
            lambda m: m.update(private_note="do-not-export"),
            lambda m: m.update(version=2),
            lambda m: m.update(version=True),
            lambda m: m.update(files={}),
            lambda m: m["files"][0].update(private_note="do-not-export"),
            lambda m: m["files"][0].update(executable="false"),
            lambda m: m["files"][0].update(sha256="invalid"),
            lambda m: m["files"][0].update(path=42),
        ]
        baseline = json.dumps(self.manifest)
        for mutate in mutations:
            with self.subTest(mutate=mutate):
                self.manifest = json.loads(baseline)
                mutate(self.manifest)
                self.write_manifest()
                with self.assertRaises(ValueError) as error:
                    release.load_manifest(self.root)
                self.assertNotIn("do-not-export", str(error.exception))

    def test_manifest_content_is_scanned(self):
        result = "\n".join(release.audit(self.root, self.entries, ["README"]))
        self.assertIn("release-files.json:", result)
        self.assertIn("private pattern 1", result)

    def test_export_audits_source_even_when_called_directly(self):
        (self.root / "README.md").write_text("not reviewed")
        dest = Path(self.tmp.name) / "export"
        with self.assertRaises(ValueError):
            release.export(self.root, dest, self.entries)
        self.assertFalse(dest.exists())

    def test_export_preserves_deny_patterns(self):
        dest = Path(self.tmp.name) / "export"
        with self.assertRaises(ValueError):
            release.export(self.root, dest, self.entries, ["public"])
        self.assertFalse(dest.exists())
        with patch.object(release, "audit", wraps=release.audit) as audit:
            release.export(self.root, dest, self.entries, ["nonmatching-private-pattern"])
            self.assertEqual(audit.call_count, 2)
            for call in audit.call_args_list:
                self.assertEqual(call.args[2], ["nonmatching-private-pattern"])

    def test_source_symlink_race_never_changes_external_permissions(self):
        private = Path(self.tmp.name) / "private-fixture"
        private.write_text("dummy private fixture")
        private.chmod(0o600)
        original = release.reviewed_bytes
        def replace_source(root_fd, entry):
            source = self.root / entry["path"]
            source.unlink()
            source.symlink_to(private)
            return original(root_fd, entry)
        dest = Path(self.tmp.name) / "export"
        with patch.object(release, "reviewed_bytes", side_effect=replace_source):
            with self.assertRaises(OSError):
                release.export(self.root, dest, self.entries)
        self.assertEqual(private.stat().st_mode & 0o777, 0o600)
        self.assertEqual(dest.stat().st_mode & 0o777, 0o700)
        self.assertFalse((dest / "README.md").exists())

    def test_source_content_race_is_rejected_before_exporting_bytes(self):
        original = release.reviewed_bytes
        def replace_source(root_fd, entry):
            (self.root / entry["path"]).write_text("unreviewed replacement")
            return original(root_fd, entry)
        dest = Path(self.tmp.name) / "export"
        with patch.object(release, "reviewed_bytes", side_effect=replace_source):
            with self.assertRaisesRegex(ValueError, "changed since review"):
                release.export(self.root, dest, self.entries)
        self.assertEqual(dest.stat().st_mode & 0o777, 0o700)
        self.assertFalse((dest / "README.md").exists())

    def test_source_parent_symlink_race_is_rejected(self):
        directory = self.root / "nested"
        directory.mkdir()
        (self.root / "README.md").rename(directory / "README.md")
        self.entries[0]["path"] = "nested/README.md"
        self.write_manifest()
        original = release.reviewed_bytes
        def replace_parent(root_fd, entry):
            saved = Path(self.tmp.name) / "outside"
            directory.rename(saved)
            directory.symlink_to(saved, target_is_directory=True)
            return original(root_fd, entry)
        dest = Path(self.tmp.name) / "export"
        with patch.object(release, "reviewed_bytes", side_effect=replace_parent):
            with self.assertRaises(OSError):
                release.export(self.root, dest, self.entries)
        self.assertEqual(dest.stat().st_mode & 0o777, 0o700)

    def test_clean_export_has_no_history_or_ignored_files(self):
        (self.root / ".git").mkdir()
        (self.root / ".git/config").write_text("private remote")
        (self.root / "target").mkdir()
        (self.root / "target/local").write_text("private path")
        self.assertEqual(release.audit(self.root, self.entries), [])
        dest = Path(self.tmp.name) / "export"
        release.export(self.root, dest, self.entries)
        self.assertEqual({p.name for p in dest.iterdir()}, {"README.md", release.MANIFEST})
        with self.assertRaises(ValueError):
            release.export(self.root, dest, self.entries)

    def test_new_file_rejected(self):
        (self.root / "secret.env").write_text("not reviewed")
        self.assertTrue(release.audit(self.root, self.entries))

    def test_changed_file_rejected(self):
        (self.root / "README.md").write_text("changed")
        self.assertTrue(release.audit(self.root, self.entries))

    def test_changed_executable_mode_rejected(self):
        (self.root / "README.md").chmod(0o755)
        self.assertTrue(release.audit(self.root, self.entries))

    def test_export_inside_source_rejected(self):
        with self.assertRaises(ValueError):
            release.export(self.root, self.root / "nested", self.entries)

    def test_symlink_rejected(self):
        (self.root / "link").symlink_to("/etc/passwd")
        self.assertTrue(release.audit(self.root, self.entries))

    def test_secret_value_not_printed(self):
        value = "ghp_" + "a" * 40
        (self.root / "README.md").write_text(value)
        result = "\n".join(release.audit(self.root, self.entries))
        self.assertIn("GitHub token", result)
        self.assertNotIn(value, result)

    def test_path_escape_rejected(self):
        for path in ["../hosts/private.nix", "/etc/passwd", ".git/config", "a/../b"]:
            with self.assertRaises(ValueError):
                release.safe_path(path)


if __name__ == "__main__":
    unittest.main()
