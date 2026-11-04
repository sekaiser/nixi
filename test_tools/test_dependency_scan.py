"""Public coverage and failure semantics; synthetic scanners, no network/hosts."""
from contextlib import redirect_stdout
import copy
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import dependency_scan as scan


def result(code, value, stderr=b""):
    return subprocess.CompletedProcess([], code, json.dumps(value).encode(), stderr)


class DependencyScan(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="nixi-coverage-")
        self.addCleanup(temporary.cleanup)
        self.tmp = Path(temporary.name).resolve()
        self.row = {"name": "example-1.0", "pname": "example", "version": "1.0",
                    "derivation": "/nix/store/" + "a" * 32 + "-example-1.0.drv",
                    "affected_by": ["CVE-2026-12345"], "whitelisted": []}
        self.npm = {"auditReportVersion": 2, "vulnerabilities": {}, "metadata": {"vulnerabilities": {
            "info": 0, "low": 0, "moderate": 0, "high": 0, "critical": 0, "total": 0}}}

    def targets(self, system):
        coverage = scan.policy(ROOT)
        names = {"framework/" + name for name, mode in coverage["frameworkPackages"].items() if mode == "scan"}
        names.add("editor/emacs-base")
        if system.endswith("-linux"):
            names |= {"service/" + name for name in scan.SERVICES}
        return {"system": system, "targets": {name: {
            "kind": name.split("/")[0], "name": "example", "version": "1.0",
            "drvPath": "/nix/store/" + "a" * 32 + "-example-1.0.drv"} for name in names}, "addonPins": {}}

    def test_inventory_classifies_all_shipped_packages_and_records_gaps(self):
        coverage = scan.policy(ROOT)
        self.assertEqual(len(coverage["frameworkPackages"]), 15)
        self.assertEqual(sum(mode == "scan" for mode in coverage["frameworkPackages"].values()), 12)
        self.assertGreaterEqual({x["id"] for x in coverage["components"]},
                                {"janet-vendor", "memorycore-npm", "optional-services", "emacs-and-doom", "cluster-images", "opaque-bundles"})
        self.assertGreaterEqual({x["id"] for x in coverage["exclusions"]},
                                {"doom-resolved-packages", "container-layers", "bundled-native-libraries", "consumer-selections"})
        value = scan.inventory(ROOT, scan.release.load_manifest(ROOT), coverage)
        self.assertEqual(value["source"]["flakeLockSHA256"], scan.digest(ROOT / "flake.lock"))
        self.assertEqual(len(value["npmLock"]["packages"]), 169)
        self.assertNotIn("resolved", json.dumps(value["npmLock"]))

    def test_new_unclassified_package_fails_policy(self):
        files = list((ROOT / "packages").glob("*.nix")) + [ROOT / "packages/unreviewed.nix"]
        original = Path.glob
        def glob(path, pattern):
            return iter(files) if path == ROOT / "packages" else original(path, pattern)
        with patch.object(Path, "glob", glob):
            with self.assertRaises(ValueError):
                scan.policy(ROOT)

    def test_private_consumer_root_is_refused_before_evaluation(self):
        (self.tmp / "hosts").mkdir()
        with self.assertRaises(ValueError):
            scan.public_root(self.tmp)

    def test_json_load_refuses_special_files_duplicate_keys_and_oversize(self):
        path = self.tmp / "input"
        os.mkfifo(path)
        with self.assertRaises(ValueError):
            scan.load(path)
        path.unlink()
        path.write_text('{"a":1,"a":2}')
        with self.assertRaises(ValueError):
            scan.load(path)
        with patch.object(scan, "LIMIT", 2):
            with self.assertRaises(ValueError):
                scan.load(path)

    def test_target_evaluation_covers_exact_platform_roots_without_builds(self):
        for system in sorted(scan.SYSTEMS):
            calls = []
            def runner(argv, cwd, **kwargs):
                calls.append((argv, kwargs))
                return result(0, self.targets(system))
            value = scan.evaluate(ROOT, system, runner)
            self.assertEqual(len(value["targets"]), 13 if system.endswith("darwin") else 18)
            argv, kwargs = calls[0]
            self.assertEqual(argv[:2], ["nix", "eval"])
            for flag in ("--no-write-lock-file", "--no-update-lock-file", "allow-import-from-derivation", "max-jobs", "builders"):
                self.assertIn(flag, argv)
            self.assertEqual(kwargs["env"]["NIXI_DEPENDENCY_SYSTEM"], system)

    def test_failed_partial_missing_extra_or_private_targets_are_incomplete(self):
        base = self.targets("x86_64-linux")
        bad = []
        value = copy.deepcopy(base)
        value["targets"].pop(next(iter(value["targets"])))
        bad.append(value)
        value = copy.deepcopy(base)
        value["targets"]["private/host"] = next(iter(value["targets"].values()))
        bad.append(value)
        value = copy.deepcopy(base)
        next(iter(value["targets"].values()))["drvPath"] = "/private/SYNTHETIC_PRIVATE_VALUE"
        bad.append(value)
        for value in bad:
            with self.assertRaises(ValueError):
                scan.evaluate(ROOT, "x86_64-linux", lambda *a, **kw: result(0, value))
        with self.assertRaises(ValueError):
            scan.evaluate(ROOT, "x86_64-linux", lambda *a, **kw: result(1, base))

    def test_vulnix_findings_and_no_matches_require_consistent_protocol(self):
        self.assertEqual(scan.vulnix_result(result(0, [])), [])
        self.assertEqual(scan.vulnix_result(result(2, [self.row]))[0]["affected_by"], ["CVE-2026-12345"])
        for response in (result(2, []), result(0, [self.row]), result(1, []), result(2, {"error": "failure"}),
                         result(0, [], b"metadata missing"), result(2, [self.row], b"database error")):
            with self.assertRaises(ValueError):
                scan.vulnix_result(response)

    def test_malformed_findings_or_suppression_are_not_clean(self):
        for change in ({"affected_by": []}, {"affected_by": ["invalid"]}, {"whitelisted": ["CVE-2026-12345"]},
                       {"derivation": "/private/path"}, {"version": None}):
            row = dict(self.row, **change)
            with self.assertRaises(ValueError):
                scan.vulnix_result(result(2, [row]))

    def test_scan_passes_only_derived_roots_and_disables_suppressions(self):
        calls = []
        def runner(argv, cwd, **kwargs):
            calls.append(argv)
            return result(0, self.targets("x86_64-linux") if argv[0] == "nix" else [])
        value = scan.scan_nix(ROOT, "x86_64-linux", "vulnix-fixture", runner)
        self.assertEqual(value["status"], "no-matches")
        self.assertEqual(calls[1][:4], ["vulnix-fixture", "--no-default-whitelist", "--json", "--"])
        self.assertEqual(len(calls[1][4:]), 1)  # Shared fixture drv is deduplicated.
        for forbidden in ("--system", "--gc-roots", "--closure", "--whitelist"):
            self.assertNotIn(forbidden, calls[1])

    def test_npm_counts_schema_and_status_must_agree(self):
        self.assertEqual(scan.npm_result(result(0, self.npm)), [])
        value = copy.deepcopy(self.npm)
        value["vulnerabilities"] = {"example": {"name": "example", "severity": "high", "via": ["dependency"]}}
        value["metadata"]["vulnerabilities"].update(high=1, total=1)
        self.assertEqual(scan.npm_result(result(1, value)), [{"name": "example", "severity": "high", "via": [{"package": "dependency"}]}])
        for response in (result(1, self.npm), result(0, value), result(0, {"error": "network"}),
                         result(0, self.npm, b"registry error")):
            with self.assertRaises(ValueError):
                scan.npm_result(response)
        value["metadata"]["vulnerabilities"]["total"] = 0
        with self.assertRaises(ValueError):
            scan.npm_result(result(1, value))

    def test_npm_preserves_only_validated_advisory_identifiers(self):
        value = copy.deepcopy(self.npm)
        value["metadata"]["vulnerabilities"].update(high=1, total=1)
        value["vulnerabilities"] = {"example": {"name": "example", "severity": "high", "via": [
            {"url": "https://github.com/advisories/GHSA-abcd-1234-5678", "title": "SYNTHETIC_PRIVATE_VALUE"}]}}
        findings = scan.npm_result(result(1, value))
        self.assertEqual(findings[0]["via"], [{"advisory": "GHSA-abcd-1234-5678"}])
        self.assertNotIn("SYNTHETIC_PRIVATE_VALUE", json.dumps(findings))
        value["vulnerabilities"]["example"]["via"][0]["url"] = "https://user:private@example.invalid"
        with self.assertRaises(ValueError):
            scan.npm_result(result(1, value))

    def test_npm_uses_only_scratch_public_lock_and_no_inherited_credentials(self):
        original = (ROOT / "assets/agent-memory/package-lock.json").read_bytes()
        def runner(argv, cwd, **kwargs):
            self.assertNotEqual(cwd, ROOT / "assets/agent-memory")
            self.assertEqual((cwd / "package-lock.json").read_bytes(), original)
            self.assertEqual((cwd / "user.npmrc").read_text(), "")
            self.assertEqual((cwd / "global.npmrc").read_text(), "")
            self.assertNotIn("NPM_TOKEN", kwargs["env"])
            self.assertNotIn("npm_config_registry", kwargs["env"])
            for flag in ("--package-lock-only", "--omit=dev", "--ignore-scripts", "--registry=https://registry.npmjs.org/"):
                self.assertIn(flag, argv)
            self.assertNotIn("fix", argv)
            return result(0, self.npm)
        with patch.dict(os.environ, NPM_TOKEN="SYNTHETIC_PRIVATE_VALUE", npm_config_registry="https://private.invalid"):
            self.assertEqual(scan.scan_npm(ROOT, "npm-fixture", runner)["status"], "no-matches")
        self.assertEqual((ROOT / "assets/agent-memory/package-lock.json").read_bytes(), original)

    def test_npm_lock_mutation_is_incomplete(self):
        def runner(argv, cwd, **kwargs):
            (cwd / "package-lock.json").write_text("{}")
            return result(0, self.npm)
        with self.assertRaises(ValueError):
            scan.scan_npm(ROOT, "npm-fixture", runner)

    def test_command_capture_bounds_output_time_and_failure(self):
        value = scan.run([sys.executable, "-c", "print('ok')"], self.tmp, timeout=2)
        self.assertEqual(value.stdout.strip(), b"ok")
        with self.assertRaises(TimeoutError):
            scan.run([sys.executable, "-c", "import time; time.sleep(10)"], self.tmp, timeout=0.1)
        with patch.object(scan, "LIMIT", 10):
            with self.assertRaises((ValueError, TimeoutError)):
                scan.run([sys.executable, "-c", "print('x' * 20)"], self.tmp, timeout=2)

    def test_main_failure_persists_incomplete_without_diagnostics(self):
        output = self.tmp / "report.json"
        with (patch.object(sys, "argv", ["scan", "nix", "--system", "x86_64-linux", "--output", str(output)]),
              patch.object(scan, "public_root", side_effect=ValueError("SYNTHETIC_PRIVATE_VALUE")), redirect_stdout(io.StringIO()) as stdout):
            self.assertEqual(scan.main(), 2)
        value = json.loads(output.read_text())
        self.assertEqual(value["status"], "incomplete")
        self.assertNotIn("SYNTHETIC_PRIVATE_VALUE", output.read_text() + stdout.getvalue())

    def test_main_stages_allowlist_and_never_imports_ignored_files(self):
        (self.tmp / "public.txt").write_text("public fixture\n")
        (self.tmp / ".cache").mkdir()
        (self.tmp / ".cache/ignored-private").write_text("SYNTHETIC_PRIVATE_VALUE")
        entry = {"path": "public.txt", "sha256": hashlib.sha256((self.tmp / "public.txt").read_bytes()).hexdigest(), "executable": False}
        (self.tmp / "release-files.json").write_text(json.dumps({"version": 1, "files": [entry]}))
        output = self.tmp / "result.json"
        def staged(root, *args):
            self.assertNotEqual(root, self.tmp)
            self.assertTrue((root / "public.txt").exists())
            self.assertFalse((root / ".cache").exists())
            return {"status": "no-matches", "findings": []}
        with (patch.object(sys, "argv", ["scan", "nix", "--system", "x86_64-linux", "--output", str(output)]),
              patch.object(scan, "public_root", return_value=(self.tmp, [entry], {})),
              patch.object(scan, "inventory", return_value={"exclusions": ["fixture"]}),
              patch.object(scan, "scan_nix", side_effect=staged), redirect_stdout(io.StringIO())):
            self.assertEqual(scan.main(), 0)
        self.assertNotIn("SYNTHETIC_PRIVATE_VALUE", output.read_text())


if __name__ == "__main__":
    unittest.main()
