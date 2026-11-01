"""Writable OMP configuration contract; synthetic data only."""
import importlib.util
import os
from pathlib import Path
import stat
import tempfile
import unittest
from unittest.mock import patch

import yaml

spec = importlib.util.spec_from_file_location("sync_omp_config", Path(__file__).parents[1] / "tools/sync_omp_config.py")
tool = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tool)


class ConfigTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name).resolve()
        self.defaults = self.root / "defaults.yml"
        self.defaults.write_text("theme:\n  dark: titanium\nmodelRoles:\n  slow: example/model\n")
        self.config = self.root / "agent/config.yml"

    def tearDown(self):
        self.tmp.cleanup()

    def test_creates_private_writable_regular_config(self):
        tool.sync(self.defaults, self.config)
        self.assertFalse(self.config.is_symlink())
        self.assertEqual(stat.S_IMODE(self.config.stat().st_mode), 0o600)
        self.assertEqual(self.config.stat().st_uid, os.getuid())
        self.assertEqual(yaml.safe_load(self.config.read_text())["theme"]["dark"], "titanium")

    def test_preserves_unmanaged_settings_and_is_idempotent(self):
        self.config.parent.mkdir(mode=0o700)
        self.config.write_text("theme:\n  light: custom\nstartup:\n  quiet: true\nprivateExample: SYNTHETIC_VALUE\n")
        self.config.chmod(0o600)
        tool.sync(self.defaults, self.config)
        first = self.config.read_bytes()
        data = yaml.safe_load(first)
        self.assertEqual(data["theme"]["light"], "custom")
        self.assertTrue(data["startup"]["quiet"])
        self.assertEqual(data["privateExample"], "SYNTHETIC_VALUE")
        self.assertNotIn(b"SYNTHETIC_VALUE", self.config.with_name("config.yml.nixi-managed.json").read_bytes())
        tool.sync(self.defaults, self.config)
        self.assertEqual(first, self.config.read_bytes())

    def test_retired_defaults_do_not_remove_user_edits(self):
        tool.sync(self.defaults, self.config)
        data = yaml.safe_load(self.config.read_text())
        data["modelRoles"]["slow"] = "user-changed"
        self.config.write_text(yaml.safe_dump(data))
        self.defaults.write_text("symbolPreset: unicode\n")
        tool.sync(self.defaults, self.config)
        data = yaml.safe_load(self.config.read_text())
        self.assertEqual(data["modelRoles"]["slow"], "user-changed")
        self.assertNotIn("dark", data["theme"])

    def test_rejects_nonstore_symlink_without_touching_target(self):
        target = self.root / "target"
        target.write_text("do-not-touch")
        self.config.parent.mkdir(mode=0o700)
        self.config.symlink_to(target)
        with self.assertRaises(ValueError):
            tool.sync(self.defaults, self.config)
        self.assertEqual(target.read_text(), "do-not-touch")
        self.assertTrue(self.config.is_symlink())

    def test_legacy_store_link_becomes_writable_with_private_backup(self):
        self.config.parent.mkdir(mode=0o700)
        target = Path("/nix/store/synthetic-omp-config.yml")
        self.config.symlink_to(target)
        original = b"startup:\n  quiet: true\n"
        read = tool.read
        def fake_read(path, private=True):
            return original if path == target else read(path, private=private)
        with patch.object(Path, "resolve", return_value=target), patch.object(tool, "read", side_effect=fake_read):
            tool.sync(self.defaults, self.config)
        self.assertFalse(self.config.is_symlink())
        self.assertTrue(yaml.safe_load(self.config.read_text())["startup"]["quiet"])
        backup = self.config.with_name("config.yml.before-nixi-migration")
        self.assertEqual(backup.read_bytes(), original)
        self.assertEqual(stat.S_IMODE(backup.stat().st_mode), 0o600)

    def test_unreadable_store_link_is_preserved(self):
        self.config.parent.mkdir(mode=0o700)
        target = Path("/nix/store/synthetic-omp-config.yml")
        self.config.symlink_to(target)
        read = tool.read
        def fake_read(path, private=True):
            if path == target:
                raise PermissionError("SYNTHETIC_PRIVATE_VALUE")
            return read(path, private=private)
        with patch.object(Path, "resolve", return_value=target), patch.object(tool, "read", side_effect=fake_read):
            with self.assertRaises(PermissionError):
                tool.sync(self.defaults, self.config)
        self.assertTrue(self.config.is_symlink())
        self.assertFalse(self.config.with_name("config.yml.before-nixi-migration").exists())

    def test_rejects_aliases_duplicate_keys_and_malformed_yaml(self):
        self.config.parent.mkdir(mode=0o700)
        for content in ("x: &a [1]\ny: *a\n", "x: 1\nx: 2\n", "x: [\n", "!!python/object/apply:os.system ['false']"):
            self.config.write_text(content)
            self.config.chmod(0o600)
            with self.assertRaises(Exception):
                tool.sync(self.defaults, self.config)
            self.assertEqual(self.config.read_text(), content)

    def test_refuses_root_and_insecure_runtime_config(self):
        with patch.object(tool.os, "geteuid", return_value=0):
            with self.assertRaises(ValueError):
                tool.sync(self.defaults, self.config)
        self.config.parent.mkdir(mode=0o700)
        self.config.write_text("x: 1\n")
        self.config.chmod(0o644)
        with self.assertRaises(ValueError):
            tool.sync(self.defaults, self.config)

    def test_rejects_symlinked_directory_and_metadata(self):
        real = self.root / "real"
        real.mkdir(mode=0o700)
        self.config.parent.symlink_to(real)
        with self.assertRaises(ValueError):
            tool.sync(self.defaults, self.config)
        self.config.parent.unlink()
        tool.sync(self.defaults, self.config)
        metadata = self.config.with_name("config.yml.nixi-managed.json")
        metadata.unlink()
        metadata.symlink_to(self.defaults)
        with self.assertRaises(OSError):
            tool.sync(self.defaults, self.config)


if __name__ == "__main__":
    unittest.main()
