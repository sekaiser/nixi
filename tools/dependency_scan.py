"""Representative public dependency inventory/scans; never a host/closure scan.

0: selected scans finished without matches (or offline inventory succeeded).
1: selected scans finished with advisory candidates. 2: incomplete/refused.
Known exclusions are always recorded; no result certifies release safety.
"""
import argparse
from collections import Counter
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import sys
import tempfile
import time

import release

ROOT = Path(__file__).resolve().parents[1]
SYSTEMS = {"aarch64-darwin", "aarch64-linux", "x86_64-linux"}
SERVICES = {"caddy", "docker", "gitea", "k3s", "tailscale"}
LIMIT = 32 * 1024 * 1024
DRV = re.compile(r"/nix/store/[0-9a-z]{32}-[A-Za-z0-9+._?=-]+\.drv")
CVE = re.compile(r"CVE-[0-9]{4}-[0-9]{4,}")


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def decode(data):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("duplicate-json-key")
            result[key] = value
        return result
    return json.loads(data, object_pairs_hook=unique)


def load(path):
    with os.fdopen(os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW), "rb") as stream:
        if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
            raise ValueError("regular-json-required")
        data = stream.read(LIMIT + 1)
    if len(data) > LIMIT:
        raise ValueError("input-limit")
    return decode(data)


def policy(root):
    value = load(root / "security/dependency-coverage.json")
    if (not isinstance(value, dict) or set(value) != {"version", "systems", "frameworkPackages", "services", "components", "exclusions"}
            or type(value["version"]) is not int or value["version"] != 1
            or set(value["systems"]) != SYSTEMS or len(value["systems"]) != 3
            or set(value["services"]) != SERVICES or len(value["services"]) != 5
            or not isinstance(value["frameworkPackages"], dict)
            or set(value["frameworkPackages"]) != {p.stem for p in (root / "packages").glob("*.nix")}
            or not all(v in ("scan", "via-hey", "data-only") for v in value["frameworkPackages"].values())
            or not value["components"] or not value["exclusions"]):
        raise ValueError("coverage-policy")
    identifiers = set()
    for entry in value["components"] + value["exclusions"]:
        if (not isinstance(entry, dict) or not isinstance(entry.get("id"), str)
                or not re.fullmatch(r"[a-z][a-z0-9-]+", entry["id"]) or entry["id"] in identifiers):
            raise ValueError("coverage-entry")
        identifiers.add(entry["id"])
    for component in value["components"]:
        if set(component) != {"id", "sources", "coverage"} or not isinstance(component["coverage"], str) or not component["coverage"]:
            raise ValueError("component-schema")
        for name in component["sources"]:
            if (not isinstance(name, str) or name.startswith("/") or any(p in ("", ".", "..") for p in name.split("/"))
                    or not (root / name).exists()):
                raise ValueError("component-source")
    if any(set(e) != {"id", "reason"} or not isinstance(e["reason"], str) or not e["reason"] for e in value["exclusions"]):
        raise ValueError("exclusion-schema")
    return value


def public_root(root):
    root = root.resolve()
    if (root / "hosts").exists() or not (root / "release-files.json").is_file():
        raise ValueError("public-export-required")
    entries = release.load_manifest(root)
    if release.audit(root, entries, []):
        raise ValueError("reviewed-export-required")
    return root, entries, policy(root)


def inventory(root, entries, coverage):
    files = {entry["path"]: entry["sha256"] for entry in entries}
    components = []
    for component in coverage["components"]:
        selected = {name: sha for name, sha in files.items()
                    if any(name == prefix or name.startswith(prefix + "/") for prefix in component["sources"])}
        if not selected:
            raise ValueError("inventory-source-missing")
        components.append({**component, "sourceFiles": selected})
    lock = load(root / "assets/agent-memory/package-lock.json")
    if lock.get("lockfileVersion") != 3 or not isinstance(lock.get("packages"), dict) or not lock["packages"]:
        raise ValueError("npm-lock-schema")
    dependencies = []
    for name, entry in sorted(lock["packages"].items()):
        if not name:
            continue
        if (not name.startswith("node_modules/") or not isinstance(entry, dict)
                or not isinstance(entry.get("version"), str)
                or any(type(entry.get(flag, False)) is not bool for flag in ("dev", "optional"))):
            raise ValueError("npm-lock-entry")
        dependencies.append({"path": name, "version": entry["version"], "dev": entry.get("dev", False),
                             "optional": entry.get("optional", False)})
    return {"source": {"releaseManifestSHA256": digest(root / "release-files.json"),
                       "flakeLockSHA256": digest(root / "flake.lock"),
                       "coveragePolicySHA256": digest(root / "security/dependency-coverage.json")},
            "frameworkPackages": coverage["frameworkPackages"], "components": components,
            "npmLock": {"sha256": digest(root / "assets/agent-memory/package-lock.json"), "packages": dependencies},
            "exclusions": coverage["exclusions"], "scope": "Representative public sources and scan roots; not a complete resolved SBOM or private inventory."}


def run(argv, cwd, env=None, timeout=600):
    """Bound file-backed captures and reap this command's process group."""
    with tempfile.TemporaryFile() as out, tempfile.TemporaryFile() as err:
        process = subprocess.Popen(argv, cwd=cwd, env=env, stdin=subprocess.DEVNULL,
                                   stdout=out, stderr=err, start_new_session=True)
        try:
            until = time.monotonic() + timeout
            while process.poll() is None:
                if time.monotonic() >= until or max(os.fstat(out.fileno()).st_size, os.fstat(err.fileno()).st_size) > LIMIT:
                    raise TimeoutError("capture-or-time-limit")
                time.sleep(0.05)
            if max(os.fstat(out.fileno()).st_size, os.fstat(err.fileno()).st_size) > LIMIT:
                raise ValueError("capture-limit")
            out.seek(0)
            err.seek(0)
            return subprocess.CompletedProcess(argv, process.returncode, out.read(), err.read())
        finally:
            # Descendants may keep capture descriptors after the parent exits.
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()


def evaluate(root, system, runner=run):
    env = dict(os.environ, NIXI_DEPENDENCY_ROOT=str(root), NIXI_DEPENDENCY_SYSTEM=system)
    result = runner(["nix", "eval", "--impure", "--json", "--no-write-lock-file", "--no-update-lock-file",
                     "--option", "allow-import-from-derivation", "false", "--option", "accept-flake-config", "false",
                     "--option", "max-jobs", "0", "--option", "builders", "",
                     "--file", str(root / "security/dependency-targets.nix"), "--apply",
                     'f: f {root = builtins.getEnv "NIXI_DEPENDENCY_ROOT"; system = builtins.getEnv "NIXI_DEPENDENCY_SYSTEM";}'],
                    root, env=env)
    if result.returncode != 0:
        raise ValueError("target-evaluation-failed")
    value = decode(result.stdout)
    coverage = policy(root)
    expected = {"framework/" + name for name, mode in coverage["frameworkPackages"].items() if mode == "scan"} | {"editor/emacs-base"}
    if system.endswith("-linux"):
        expected |= {"service/" + name for name in SERVICES}
    if (not isinstance(value, dict) or value.get("system") != system or not isinstance(value.get("targets"), dict)
            or set(value["targets"]) != expected):
        raise ValueError("target-coverage-mismatch")
    for name, target in value["targets"].items():
        if (not isinstance(target, dict) or set(target) != {"kind", "name", "version", "drvPath"}
                or target["kind"] != name.split("/")[0]
                or not isinstance(target["name"], str) or not re.fullmatch(r"[A-Za-z0-9+._-]{1,256}", target["name"])
                or not (target["version"] is None or isinstance(target["version"], str) and re.fullmatch(r"[A-Za-z0-9+._-]{1,256}", target["version"]))
                or not isinstance(target.get("drvPath"), str) or not DRV.fullmatch(target["drvPath"])):
            raise ValueError("invalid-public-derivation")
    return value


def vulnix_result(result):
    if result.stderr.strip():
        raise ValueError("scanner-diagnostics-require-review")
    rows = decode(result.stdout)
    if not isinstance(rows, list):
        raise ValueError("scanner-schema")
    findings = []
    for row in rows:
        if (not isinstance(row, dict) or not isinstance(row.get("affected_by"), list) or not row["affected_by"]
                or not all(isinstance(cve, str) and CVE.fullmatch(cve) for cve in row["affected_by"])
                or row.get("whitelisted", []) != [] or not isinstance(row.get("derivation"), str)
                or not DRV.fullmatch(row["derivation"])
                or any(not isinstance(row.get(k), str) or not row[k] for k in ("name", "pname", "version"))):
            raise ValueError("scanner-row-schema")
        findings.append({key: row[key] for key in ("name", "pname", "version", "derivation", "affected_by")})
    # Vulnix uses exit 2 for both findings and some errors. Require its complete
    # JSON findings schema, no diagnostics and a consistent exit status.
    if result.returncode != (2 if findings else 0):
        raise ValueError("scanner-status-mismatch")
    return findings


def npm_result(result):
    if result.stderr.strip():
        raise ValueError("npm-diagnostics-require-review")
    data = decode(result.stdout)
    if (not isinstance(data, dict) or data.get("auditReportVersion") != 2 or "error" in data
            or not isinstance(data.get("vulnerabilities"), dict)):
        raise ValueError("npm-audit-schema")
    counts = data.get("metadata", {}).get("vulnerabilities", {})
    if (set(counts) != {"info", "low", "moderate", "high", "critical", "total"}
            or any(type(v) is not int or v < 0 for v in counts.values())
            or sum(v for k, v in counts.items() if k != "total") != counts["total"]
            or counts["total"] != len(data["vulnerabilities"])):
        raise ValueError("npm-audit-counts")
    findings = []
    for name, value in data["vulnerabilities"].items():
        if (not re.fullmatch(r"(?:@[a-z0-9._-]+/)?[a-z0-9._-]+", name) or not isinstance(value, dict)
                or value.get("name") != name or value.get("severity") not in counts
                or value["severity"] == "total" or not isinstance(value.get("via"), list)):
            raise ValueError("npm-audit-entry")
        via = []
        for entry in value["via"]:
            if isinstance(entry, str) and re.fullmatch(r"(?:@[a-z0-9._-]+/)?[a-z0-9._-]+", entry):
                via.append({"package": entry})
            elif isinstance(entry, dict) and isinstance(entry.get("url"), str):
                advisory = re.fullmatch(r"https://github\.com/advisories/(GHSA-[a-z0-9]{4}-[a-z0-9]{4}-[a-z0-9]{4})", entry["url"])
                if not advisory:
                    raise ValueError("unsupported-npm-advisory-url")
                via.append({"advisory": advisory.group(1)})
            else:
                raise ValueError("unsupported-npm-advisory")
        # Publish identifiers, never raw titles, URLs, diagnostics or commands.
        findings.append({"name": name, "severity": value["severity"], "via": via})
    severities = Counter(finding["severity"] for finding in findings)
    if any(severities[key] != counts[key] for key in counts if key != "total"):
        raise ValueError("npm-severity-counts")
    if result.returncode != (1 if findings else 0):
        raise ValueError("npm-status-mismatch")
    return findings


def scan_nix(root, system, scanner, runner=run):
    targets = evaluate(root, system, runner)
    paths = sorted({entry["drvPath"] for entry in targets["targets"].values()})
    result = runner([scanner, "--no-default-whitelist", "--json", "--", *paths], root)
    findings = vulnix_result(result)
    return {"system": system, "targets": targets["targets"], "addonPins": targets["addonPins"],
            "scanner": "vulnix", "scope": "Derivation/build dependencies; outputs and hosts are not built or activated.",
            "status": "findings" if findings else "no-matches", "findings": findings}


def scan_npm(root, npm, runner=run):
    with tempfile.TemporaryDirectory(prefix="nixi-public-npm-") as directory:
        work = Path(directory)
        for name in ("package.json", "package-lock.json"):
            (work / name).write_bytes((root / "assets/agent-memory" / name).read_bytes())
        for name in ("user.npmrc", "global.npmrc"):
            (work / name).write_text("")
        env = {key: value for key, value in os.environ.items()
               if not key.lower().startswith("npm_config_") and key.upper() not in {"NPM_TOKEN", "NODE_AUTH_TOKEN", "NODE_OPTIONS"}}
        env.update(HOME=str(work), NPM_CONFIG_USERCONFIG=str(work / "user.npmrc"),
                   NPM_CONFIG_GLOBALCONFIG=str(work / "global.npmrc"), NPM_CONFIG_CACHE=str(work / "cache"))
        result = runner([npm, "audit", "--json", "--package-lock-only", "--omit=dev", "--ignore-scripts",
                         "--audit-level=info", "--no-update-notifier", "--registry=https://registry.npmjs.org/"], work, env=env)
        findings = npm_result(result)
        if digest(work / "package-lock.json") != digest(root / "assets/agent-memory/package-lock.json"):
            raise ValueError("npm-mutated-lock")
    return {"scanner": "npm-audit", "lock": "assets/agent-memory/package-lock.json", "omit": ["dev"],
            "status": "findings" if findings else "no-matches", "findings": findings}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=["inventory", "nix", "npm"])
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--output", type=Path, required=True, help="New report file; existing files are never overwritten")
    parser.add_argument("--system", choices=sorted(SYSTEMS))
    parser.add_argument("--scanner", default="vulnix")
    parser.add_argument("--npm", default="npm")
    args = parser.parse_args()
    result = {"version": 1, "mode": args.mode, "status": "incomplete", "asOf": datetime.now(timezone.utc).isoformat(),
              "coverageScope": "representative-only", "advisoryDatabaseFreshness": "not-independently-verified",
              "scope": "Public representative coverage only; never a complete vulnerability or deployment assessment."}
    code = 2
    stage = "public-source-validation"
    try:
        root, entries, coverage = public_root(args.root)
        stage = "inventory"
        result.update(inventory(root, entries, coverage))
        if args.mode == "inventory":
            result["status"], code = "inventory-only", 0
        else:
            if args.mode == "nix" and args.system is None:
                raise ValueError("system-required")
            # Never import a working directory containing ignored/unlisted files
            # into the Nix store. Stage only the exact reviewed allowlist first.
            with tempfile.TemporaryDirectory(prefix="nixi-public-scan-") as directory:
                stage = "reviewed-export"
                staged = Path(directory) / "public"
                release.export(root, staged, entries, [])
                stage = "selected-scan"
                scan = scan_nix(staged, args.system, args.scanner) if args.mode == "nix" else scan_npm(staged, args.npm)
            result.update(scan)
            code = 1 if scan["findings"] else 0
    except Exception:
        # Raw command output, exception messages and unvalidated JSON are never
        # copied to reports or CI logs. Missing/failed scans stay incomplete.
        result["status"] = "incomplete"
        result["failureStage"] = stage
        result["failure"] = "Input, evaluation or scanner failure; details withheld. Review source/tool availability and rerun."
    try:
        fd = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "w") as outgoing:
            json.dump(result, outgoing, indent=2)
            outgoing.write("\n")
    except OSError:
        print("Dependency report output refused; choose a new writable report filename.", file=sys.stderr)
        return 2
    print(f"Public dependency {args.mode}: {result['status']}; exclusions remain applicable.")
    return code


if __name__ == "__main__":
    sys.exit(main())
