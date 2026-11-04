"""Synthetic dependency-policy checks. No network, Nix build or private inputs."""
import copy
from datetime import date, datetime, timezone
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import dependency_report as dependency


class DependencyReport(unittest.TestCase):
    def setUp(self):
        self.today = date(2026, 9, 10)
        self.manifest = dependency.load_json(ROOT / "security/overrides.json")
        # Keep date-boundary tests independent of the maintainer's next review.
        self.manifest["overrides"]["openssl_3_6"]["reviewed"] = "2026-09-01"
        self.manifest["overrides"]["openssl_3_6"]["reviewBy"] = "2026-10-01"
        modified = int(datetime(2026, 9, 1, tzinfo=timezone.utc).timestamp())
        self.lock = {"version": 7, "root": "workspace", "nodes": {
            "workspace": {"inputs": {"nixpkgs": "pkgs", "nixpkgs-unstable": ["nixpkgs"], "private": "hidden"}},
            "pkgs": {"locked": {"rev": "a" * 40, "lastModified": modified,
                                "url": "https://user:SYNTHETIC_PRIVATE_VALUE@example.invalid"}},
            "hidden": {"locked": {"path": "/private/SYNTHETIC_PRIVATE_VALUE"}}}}

    def test_report_follows_inputs_and_omits_private_metadata(self):
        result = dependency.report(self.lock, self.manifest, self.today, 30)
        self.assertFalse(result["reviewRequired"])
        self.assertEqual(len(result["inputs"]), 2)
        self.assertEqual(result["inputs"][1]["revision"], "a" * 40)
        self.assertEqual(result["inputs"][0]["ageDays"], 9)
        self.assertNotIn("SYNTHETIC_PRIVATE_VALUE", json.dumps(result))
        self.assertNotIn("hidden", json.dumps(result))

    def test_nested_follows_and_cycles(self):
        self.lock["nodes"]["workspace"]["inputs"]["nixpkgs-unstable"] = ["parent", "child"]
        self.lock["nodes"]["workspace"]["inputs"]["parent"] = "parent"
        self.lock["nodes"]["parent"] = {"inputs": {"child": ["nixpkgs"]}}
        self.assertEqual(dependency.locked_input(self.lock, "nixpkgs-unstable")["rev"], "a" * 40)
        self.lock["nodes"]["workspace"]["inputs"]["nixpkgs"] = ["nixpkgs-unstable"]
        with self.assertRaises(ValueError):
            dependency.report(self.lock, self.manifest, self.today, 30)

    def test_stale_missing_and_future_dates_require_review(self):
        for modified in (None, 0, 9999999999):
            self.lock["nodes"]["pkgs"]["locked"]["lastModified"] = modified
            self.assertTrue(dependency.report(self.lock, self.manifest, self.today, 30)["reviewRequired"])
        self.lock["nodes"]["workspace"]["inputs"] = {}
        self.assertTrue(dependency.report(self.lock, self.manifest, self.today, 30)["reviewRequired"])

    def test_override_deadline_flags_review_without_removing_fix(self):
        before = copy.deepcopy(self.manifest)
        entry = self.manifest["overrides"]["openssl_3_6"]
        result = dependency.override_report(self.manifest, date.fromisoformat(entry["reviewBy"]))
        self.assertTrue(result[0]["reviewDue"])
        self.assertEqual(self.manifest, before)
        self.assertEqual(result[0]["fixedVersion"], entry["fixedVersion"])

    def test_override_schema_requires_sources_advisories_and_bounded_review(self):
        for change in ({"reviewBy": "2099-01-01"}, {"reviewed": "2099-01-01"},
                       {"advisories": []}, {"validation": []},
                       {"advisories": ["https://user:password@example.invalid"]},
                       {"source": {"url": "https://example.invalid/file", "sha256": "invalid"}},
                       {"extra": "unexpected"}):
            manifest = copy.deepcopy(self.manifest)
            manifest["overrides"]["openssl_3_6"].update(change)
            with self.subTest(change=change), self.assertRaises(ValueError):
                dependency.override_report(manifest, self.today)

    def test_cli_rejects_malformed_and_special_files_without_echoing_contents(self):
        with tempfile.TemporaryDirectory(prefix="nixi-dependency-") as directory:
            file = Path(directory) / "input"
            for content in ('{"SYNTHETIC_PRIVATE_VALUE":', '{"version":7,"root":"x","nodes":null}',
                            '{"version":7,"root":"x","nodes":{"x":{"inputs":null}}}'):
                file.write_text(content)
                result = subprocess.run([sys.executable, dependency.__file__, "--lock", str(file)],
                                        capture_output=True, text=True, timeout=5)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertEqual(result.stdout, "")
                self.assertNotIn("SYNTHETIC_PRIVATE_VALUE", result.stderr)
                self.assertNotIn("Traceback", result.stderr)
            file.unlink()
            os.mkfifo(file)
            with self.assertRaises(ValueError):
                dependency.load_json(file)

    def test_public_automation_is_opt_in_read_only_and_export_scoped(self):
        workflow = (ROOT / ".github/workflows/dependency-maintenance.yml").read_text()
        for expected in ("github.event.repository.private == false", "NIXI_DEPENDENCY_MAINTENANCE == 'true'",
                         "contents: read", "persist-credentials: false", "tools/release.py export",
                         "--output-lock-file", "tools/dependency_scan.py", "allow-import-from-derivation false",
                         "retention-days: 7", "failed scan is not a clean report"):
            self.assertIn(expected, workflow)
        for forbidden in ("pull_request_target", "contents: write", "pull-requests: write", "secrets.",
                          "git push", "darwin-rebuild", "nixos-rebuild", "hey sync"):
            self.assertNotIn(forbidden, workflow)
        for action in re.findall(r"uses: ([^\s]+)", workflow):
            self.assertRegex(action, r"@[0-9a-f]{40}$")

    def test_public_advisory_coverage_includes_platforms_and_npm(self):
        import yaml
        workflow = (ROOT / ".github/workflows/dependency-maintenance.yml").read_text()
        self.assertIn("tools/dependency_scan.py", workflow)
        for system in ("x86_64-linux", "aarch64-linux", "aarch64-darwin"):
            self.assertIn(system, workflow)
        self.assertIn("--npm", workflow)
        self.assertIn("inventory.json", workflow)
        jobs = yaml.safe_load(workflow)["jobs"]
        self.assertEqual(set(jobs["scan"]["strategy"]["matrix"]["system"]),
                         {"x86_64-linux", "aarch64-linux", "aarch64-darwin"})
        self.assertFalse(jobs["scan"]["strategy"]["fail-fast"])
        for job in jobs.values():
            self.assertIn("github.event.repository.private == false", job["if"])
            self.assertIn("NIXI_DEPENDENCY_MAINTENANCE == 'true'", job["if"])


if __name__ == "__main__":
    unittest.main()
