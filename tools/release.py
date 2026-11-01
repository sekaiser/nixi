#!/usr/bin/env python3
"""Audit and export an explicitly reviewed source snapshot, never Git history.

The manifest is a review artifact, not a secret detector or security guarantee.
There is deliberately no recursive 'include everything' or publish command.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import sys

MANIFEST = "release-files.json"
IGNORED_DIRS = {".git", ".direnv", "target", "__pycache__", ".manifests", ".cache"}
EXCLUDED = {"modules/shared/themes/alucard/config/wallpaper.png"}
RULES = {
    "password hash": r"\$(?:[1567]|y|2[aby])\$[A-Za-z0-9./$]{20,}",
    "private key": r"-----BEGIN (?:RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----",
    "age secret": r"AGE-SECRET-KEY-[A-Z0-9]{20,}",
    "AWS key": r"(?:AKIA|ASIA)[A-Z0-9]{16}",
    "GitHub token": r"(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})",
    "Slack token": r"xox[baprs]-[A-Za-z0-9-]{20,}",
    "API token": r"sk-[A-Za-z0-9_-]{24,}",
}


def safe_path(name):
    if not isinstance(name, str):
        raise ValueError("Release path must be a string")
    path = PurePosixPath(name)
    if (path.is_absolute() or not path.parts or ".." in path.parts
            or str(path) != name or "\\" in name
            or any(part in {".git", ".gitmodules"} for part in path.parts)):
        raise ValueError("Unsafe release path (value redacted)")
    return path


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def ignored(name):
    parts = PurePosixPath(name).parts
    return (any(part in IGNORED_DIRS for part in parts)
            or name in EXCLUDED or name == MANIFEST
            or name.endswith((".pyc", ".janet.tested", ".zwc"))
            or parts[0] in {"dist", "release-candidate"})


def load_manifest(root):
    manifest_path = root / MANIFEST
    if manifest_path.is_symlink():
        raise ValueError("Release manifest must not be a symlink")
    manifest = json.loads(manifest_path.read_text())
    if not isinstance(manifest, dict) or set(manifest) != {"version", "files"}:
        raise ValueError("Manifest must contain only version and files")
    if type(manifest["version"]) is not int or manifest["version"] != 1:
        raise ValueError("Unsupported manifest version")
    entries = manifest["files"]
    if not isinstance(entries, list):
        raise ValueError("Manifest files must be a list")
    for entry in entries:
        if not isinstance(entry, dict) or set(entry) != {"path", "sha256", "executable"}:
            raise ValueError("Each manifest entry must contain only path, sha256 and executable")
        if not isinstance(entry["sha256"], str) or not re.fullmatch(r"[0-9a-f]{64}", entry["sha256"]):
            raise ValueError("Invalid manifest digest")
        if type(entry["executable"]) is not bool:
            raise ValueError("Manifest executable must be a boolean")
        name = entry["path"]
        safe_path(name)
        if ignored(name):
            raise ValueError("Excluded release path (value redacted)")
    if len({entry["path"] for entry in entries}) != len(entries):
        raise ValueError("Duplicate release path")
    return entries


def audit(root, entries, deny_patterns=(), check_hashes=True):
    # Validate at the API boundary too, not just in the CLI. The manifest itself
    # is exported data and must pass exactly the same content checks.
    if load_manifest(root) != entries:
        raise ValueError("Entries do not match the source manifest")
    problems = []
    allowed = {entry["path"] for entry in entries}
    for directory, dirs, files in os.walk(root, followlinks=False):
        for name in dirs + files:
            path = Path(directory) / name
            relative = path.relative_to(root).as_posix()
            if path.is_symlink():
                problems.append(f"{relative}: symlink not allowed")
            elif path.is_file() and not ignored(relative) and relative not in allowed:
                problems.append(f"{relative}: unreviewed file")
        dirs[:] = [name for name in dirs if not ignored(
            (Path(directory) / name).relative_to(root).as_posix())]
    rules = {**RULES, **{f"private pattern {i + 1}": pattern
                       for i, pattern in enumerate(deny_patterns)}}
    for entry in [*entries, {"path": MANIFEST}]:
        name = entry["path"]
        path = root / name
        parts = PurePosixPath(name).parts
        if any(root.joinpath(*parts[:i]).is_symlink() for i in range(1, len(parts) + 1)):
            problems.append(f"{name}: symlink in path")
            continue
        if not path.is_file() or not path.resolve().is_relative_to(root.resolve()):
            problems.append(f"{name}: missing or outside source root")
            continue
        if name != MANIFEST and check_hashes and digest(path) != entry["sha256"]:
            problems.append(f"{name}: changed since review")
        if name != MANIFEST and check_hashes and bool(path.stat().st_mode & 0o111) != entry["executable"]:
            problems.append(f"{name}: executable mode changed since review")
        try:
            data = path.read_bytes()
            if b"\0" in data:
                raise UnicodeError()
            content = data.decode("utf-8")
        except UnicodeError:
            problems.append(f"{name}: binary/unreviewed encoding")
            continue
        for label, pattern in rules.items():
            for match in re.finditer(pattern, content):
                line = content[:match.start()].count("\n") + 1
                problems.append(f"{name}:{line}: {label} (value redacted)")
        if name.endswith("flake.lock"):
            lock = json.loads(content)
            for node_name, node in lock.get("nodes", {}).items():
                locked = node.get("locked", {})
                if locked.get("type") in {"path", "git"}:
                    problems.append(f"{name}: review local/private-capable input {node_name}")
    return problems


def reviewed_bytes(root_fd, entry):
    """Read the exact reviewed file, refusing symlinks in every path component."""
    parts = safe_path(entry["path"]).parts
    directory = os.dup(root_fd)
    try:
        for part in parts[:-1]:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=directory)
            os.close(directory)
            directory = child
        fd = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
        with os.fdopen(fd, "rb") as incoming:
            info = os.fstat(incoming.fileno())
            if not stat.S_ISREG(info.st_mode):
                raise ValueError("Export source is not a regular file")
            if bool(info.st_mode & 0o111) != entry["executable"]:
                raise ValueError("Export source mode changed since review")
            data = incoming.read()
        if hashlib.sha256(data).hexdigest() != entry["sha256"]:
            raise ValueError("Export source changed since review")
        return data
    finally:
        os.close(directory)


def export(root, destination, entries, deny_patterns=()):
    # A new directory only: no replacement, deletion, metadata copy, or Git operations.
    if destination.exists() or destination.is_symlink():
        raise ValueError("Export destination must not exist")
    if destination.resolve().is_relative_to(root.resolve()):
        raise ValueError("Export must be outside the source tree")
    problems = audit(root, entries, deny_patterns)
    if problems:
        raise ValueError("Source audit failed: " + "; ".join(problems))
    # The new directory remains private on failure. Only a fully verified
    # snapshot is made traversable; no pathname chmod can follow a source link.
    destination.mkdir(mode=0o700, parents=False)
    source_fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for entry in entries:
            data = reviewed_bytes(source_fd, entry)
            target = destination / entry["path"]
            target.parent.mkdir(parents=True, exist_ok=True)
            with target.open("xb") as outgoing:
                outgoing.write(data)
                os.fchmod(outgoing.fileno(), 0o755 if entry["executable"] else 0o644)
        # Serialize only validated fields, never unchecked source metadata.
        with (destination / MANIFEST).open("x") as outgoing:
            outgoing.write(json.dumps({"version": 1, "files": entries}, indent=2) + "\n")
            os.fchmod(outgoing.fileno(), 0o644)
        problems = audit(destination, entries, deny_patterns)
        if problems:
            raise ValueError("Export verification failed: " + "; ".join(problems))
        destination_fd = os.open(destination, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            os.fchmod(destination_fd, 0o755)
        finally:
            os.close(destination_fd)
    finally:
        os.close(source_fd)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["audit", "export", "refresh"])
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--destination", type=Path)
    parser.add_argument("--deny-pattern", action="append", default=[])
    parser.add_argument("--reviewed", action="store_true",
                        help="Confirm manual review before refreshing existing manifest hashes")
    args = parser.parse_args()
    root = args.root.resolve()
    entries = load_manifest(root)
    problems = audit(root, entries, args.deny_pattern, check_hashes=args.command != "refresh")
    if problems:
        for problem in problems:
            print(problem, file=sys.stderr)
        return 1
    if args.command == "refresh":
        if not args.reviewed:
            parser.error("refresh requires --reviewed; new files must be listed explicitly")
        for entry in entries:
            entry["sha256"] = digest(root / entry["path"])
            entry["executable"] = bool((root / entry["path"]).stat().st_mode & 0o111)
        (root / MANIFEST).write_text(json.dumps({"version": 1, "files": entries}, indent=2) + "\n")
    elif args.command == "export":
        if not args.destination:
            parser.error("export requires --destination")
        export(root, args.destination, entries, args.deny_pattern)
    print(f"PASS: {len(entries)} allowlisted text files verified")
    print("Pattern checks are limited; human review and an independent secret scan remain required.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, OSError, KeyError) as error:
        print(f"Release refused: {error}", file=sys.stderr)
        sys.exit(1)
