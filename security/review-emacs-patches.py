#!/usr/bin/env python3
"""Qualify the reviewed Emacs 31.1 patch stack without fetching or compiling.

Consumes includePatchContent metadata from emacs-source-review.nix. Inputs must
already be reviewed and present locally. Uses a new scratch directory, GNU patch
with zero fuzz, and optionally an existing Emacs 31.1 interpreter. A failing Lisp
probe returns failure and remains in the report; it is not a remediation claim.
"""
import argparse
import base64
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import shlex
import shutil
import subprocess
import tarfile

SYSTEMS = {"aarch64-darwin", "aarch64-linux", "x86_64-linux"}
ARCHIVE_HASH = "sha256-HaV5DZWAyBkytb9wBjMRRGjaezQS1p+qdn2uv5dPRYY="
PATCH_FILES = {
    "CVE-2026-108976.patch": {"lisp/net/tramp.el", "lisp/net/tramp-archive.el"},
    "CVE-2024-53920.patch": {"lisp/progmodes/flymake.el"},
    "load-the-early-default-library-after-early-init.el.patch": {
        "doc/emacs/cmdargs.texi", "doc/emacs/custom.texi", "doc/lispref/os.texi", "lisp/startup.el"},
    "native-comp-driver-options-30.patch": {"lisp/emacs-lisp/comp.el"},
}


def sha(data):
    return hashlib.sha256(data).hexdigest()


def verify(data, expected):
    actual = "sha256-" + base64.b64encode(hashlib.sha256(data).digest()).decode()
    if actual != expected:
        raise ValueError("Input hash mismatch")


def read(path, limit):
    path = Path(path)
    if not path.is_absolute() or not path.is_file() or path.stat().st_size > limit:
        raise ValueError("Expected a bounded, absolute regular input file")
    return path.read_bytes()


def patch_paths(data):
    paths = set()
    for value in re.findall(rb"^\+\+\+ [^/]+/([^\t\n]+)", data, re.M):
        name = value.decode()
        path = PurePosixPath(name)
        if path.is_absolute() or ".." in path.parts or str(path) != name:
            raise ValueError("Unsafe patch path")
        paths.add(name)
    return paths


def patch_bytes(patch):
    if patch["template"]:
        # Replay replaceVars' one literal substitution; never execute buildPhase.
        data = read(patch["template"], 100_000)
        tokens = shlex.split(patch["buildPhase"])
        if tokens.count("--replace-fail") != 1:
            raise ValueError("Unexpected generated patch recipe")
        index = tokens.index("--replace-fail")
        old, new = tokens[index + 1:index + 3]
        if old != "@backendPath@" or data.count(old.encode()) != 1:
            raise ValueError("Unexpected generated patch placeholder")
        data = data.replace(old.encode(), new.encode())
        if b"@backendPath@" in data:
            raise ValueError("Unsubstituted patch placeholder")
        origin = "literal replaceVars replay; generated derivation not realized"
    else:
        data = read(patch["path"], 100_000)
        if patch["hash"]:
            verify(data, patch["hash"])
        origin = "Nix fixed-output fetch" if patch["hash"] else "pinned Nixpkgs file"
    if patch_paths(data) != PATCH_FILES[patch["name"]]:
        raise ValueError("Unexpected patch file set")
    return data, origin


def command(argv, **kwargs):
    return subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                          text=True, timeout=45, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--metadata", type=Path, required=True)
    parser.add_argument("--label", default="candidate-not-applied")
    parser.add_argument("--workdir", type=Path, required=True)
    parser.add_argument("--patch", type=Path, required=True)
    parser.add_argument("--emacs", type=Path)
    parser.add_argument("--supplemental-user-patch", type=Path,
                        help="Explicitly reviewed local proposal affecting only lisp/net/tramp.el; source review only")
    args = parser.parse_args()
    rows = [row for row in json.loads(read(args.metadata, 2_000_000)) if row["label"] == args.label]
    if len(rows) != 3 or {row["system"] for row in rows} != SYSTEMS:
        raise ValueError("Exactly the three supported source contexts are required")
    source = rows[0]["selected"]["source"]
    if source["hash"] != ARCHIVE_HASH or any(row["selected"]["source"]["hash"] != ARCHIVE_HASH for row in rows):
        raise ValueError("Expected the reviewed GNU Emacs 31.1 archive")
    archive = read(source["output"], 100_000_000)
    verify(archive, ARCHIVE_HASH)
    stacks = []
    for row in rows:
        patches = row["selected"]["patches"]
        if [p["name"] for p in patches] != list(PATCH_FILES):
            raise ValueError("Unexpected patch order")
        stacks.append([(p, *patch_bytes(p)) for p in patches])
    supplemental = None
    if args.supplemental_user_patch:
        supplemental = read(args.supplemental_user_patch, 100_000)
        if patch_paths(supplemental) != {"lisp/net/tramp.el"}:
            raise ValueError("The supplemental username proposal must change only lisp/net/tramp.el")
    version = command([str(args.patch), "--version"])
    if version.returncode or "GNU patch" not in version.stdout:
        raise ValueError("GNU patch is required")
    work = args.workdir
    if not work.is_absolute():
        raise ValueError("Scratch output directory must be absolute and new")
    work.mkdir(mode=0o700, parents=False, exist_ok=False)
    base = work / "baseline"
    base.mkdir()
    paths = set.union(*PATCH_FILES.values()) | {"lisp/progmodes/elisp-mode.el"}
    # Select regular files explicitly. Never extract archive paths or run hooks.
    with tarfile.open(source["output"], "r:xz") as tar:
        for name in sorted(paths):
            member = tar.getmember("emacs-31.1/" + name)
            if not member.isfile() or not 0 < member.size < 5_000_000:
                raise ValueError("Unexpected archive member")
            data = tar.extractfile(member).read()
            if len(data) != member.size:
                raise ValueError("Incomplete archive member")
            dest = base / name
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_bytes(data)
    file_hashes = lambda tree: {name: sha((tree / name).read_bytes()) for name in sorted(paths)}
    report = {"archive": source, "patchToolVersion": version.stdout.splitlines()[0],
              "baselineFiles": file_hashes(base), "systems": [], "probes": []}
    if supplemental is not None:
        report["supplementalUserPatch"] = {
            "sha256": sha(supplemental),
            "status": "source-only local proposal; not applied to the selected Nix derivation or working package",
        }
    for row, stack in zip(rows, stacks):
        tree = work / row["system"]
        shutil.copytree(base, tree)
        result = {"system": row["system"], "emacsDrvPath": row["selected"]["drvPath"], "patches": []}
        for patch, data, origin in stack:
            patchfile = work / (row["system"] + "-" + patch["name"])
            patchfile.write_bytes(data)
            argv = [str(args.patch), "--batch", "--forward", "--fuzz=0", "-p1", "-i", str(patchfile)]
            for extra in [["--dry-run"], []]:
                applied = command(argv + extra, cwd=tree)
                if applied.returncode:
                    raise ValueError("Patch application failed: " + applied.stdout)
            result["patches"].append({"name": patch["name"], "sha256": sha(data),
                                      "generation": origin, "log": applied.stdout.strip()})
        if supplemental is not None:
            # Preserve the exact upstream candidate as a negative control before
            # applying this extra, explicitly requested source-only proposal.
            if row["system"] == "aarch64-darwin":
                shutil.copytree(tree, work / "upstream-aarch64-darwin")
            patchfile = work / (row["system"] + "-supplemental-user.patch")
            patchfile.write_bytes(supplemental)
            argv = [str(args.patch), "--batch", "--forward", "--fuzz=0", "-p1", "-i", str(patchfile)]
            for extra in [["--dry-run"], []]:
                applied = command(argv + extra, cwd=tree)
                if applied.returncode:
                    raise ValueError("Supplemental patch application failed: " + applied.stdout)
            result["supplementalUserPatch"] = {"sha256": sha(supplemental), "log": applied.stdout.strip()}
        result["patchedFiles"] = file_hashes(tree)
        report["systems"].append(result)
    failed = False
    if args.emacs:
        probe = Path(__file__).resolve().parents[1] / "test_tools/probe_emacs_source.el"
        probe_trees = ["baseline"] + (["upstream-aarch64-darwin"] if supplemental is not None else []) + ["aarch64-darwin"]
        for name in probe_trees:
            home = work / ("home-" + name)
            home.mkdir()
            for sub in ["tmp", "cache", "config", "data"]:
                (home / sub).mkdir()
            env = {"HOME": str(home), "TMPDIR": str(home / "tmp"), "PATH": "/usr/bin:/bin", "LC_ALL": "C",
                   "XDG_CACHE_HOME": str(home / "cache"), "XDG_CONFIG_HOME": str(home / "config"),
                   "XDG_DATA_HOME": str(home / "data")}
            if name == "baseline":
                version = command([str(args.emacs), "--batch", "--quick", "--version"], env=env)
                if version.returncode or version.stdout.splitlines()[0] != "GNU Emacs 31.1":
                    raise ValueError("An existing GNU Emacs 31.1 interpreter is required")
                report["interpreterVersion"] = version.stdout.splitlines()[0]
            run = command([str(args.emacs), "--batch", "--quick", "--load", str(probe), str(work / name)],
                          cwd=home, env=env)
            (work / (name + "-probe.log")).write_text(run.stdout)
            report["probes"].append({"tree": name, "exit": run.returncode,
                                      "probeSha256": sha(probe.read_bytes()), "log": run.stdout})
            if name == "aarch64-darwin":
                failed = bool(run.returncode)
    (work / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print("Zero-fuzz patch application passed for three platform recipes.")
    scope = "supplemental source" if supplemental is not None else "upstream candidate"
    print("Lisp probe: " + (scope + " has unresolved regressions" if failed else
                            scope + " passed" if args.emacs else "not run"))
    return int(failed)


if __name__ == "__main__":
    raise SystemExit(main())
