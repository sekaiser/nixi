#!/usr/bin/env python3
"""Offline pin-age and temporary-override report; not a vulnerability scanner."""
import argparse
from datetime import date, datetime, timezone
import json
import os
from pathlib import Path
import re
import stat
import sys
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
INPUTS = ("nixpkgs", "nixpkgs-darwin", "nixpkgs-unstable")
MAX_BYTES = 4 * 1024 * 1024


def load_json(path):
    # A mistakenly selected FIFO must not hang a maintenance job.
    with os.fdopen(os.open(path, os.O_RDONLY | os.O_NONBLOCK), "rb") as source:
        if not stat.S_ISREG(os.fstat(source.fileno()).st_mode):
            raise ValueError("Input must be a regular JSON file")
        data = source.read(MAX_BYTES + 1)
    if len(data) > MAX_BYTES:
        raise ValueError("Input exceeds report limit")
    return json.loads(data)


def https_url(value):
    if not isinstance(value, str) or len(value) > 2048 or any(ord(c) < 33 for c in value):
        raise ValueError("Invalid advisory/source URL")
    parsed = urlsplit(value)
    if (parsed.scheme != "https" or not parsed.hostname or parsed.username is not None
            or parsed.password is not None or parsed.query):
        raise ValueError("Advisory/source URLs must be credential-free HTTPS")
    return value


def text(value):
    if not isinstance(value, str) or not value or len(value) > 2048 or any(ord(c) < 32 for c in value):
        raise ValueError("Invalid override metadata")
    return value


def override_report(manifest, today):
    if not isinstance(manifest, dict) or set(manifest) != {"version", "overrides"} or type(manifest["version"]) is not int or manifest["version"] != 1:
        raise ValueError("Unsupported override manifest")
    entries = manifest["overrides"]
    if not isinstance(entries, dict) or len(entries) > 100:
        raise ValueError("Invalid overrides")
    result = []
    for name, entry in sorted(entries.items()):
        if not re.fullmatch(r"[a-z][a-z0-9_-]*", name) or not isinstance(entry, dict) or set(entry) != {
                "fixedVersion", "source", "advisories", "reviewed", "reviewBy", "reason", "removeWhen", "validation"}:
            raise ValueError("Invalid override schema")
        if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,3}", entry["fixedVersion"]):
            raise ValueError("Invalid fixed version")
        source = entry["source"]
        if not isinstance(source, dict) or set(source) != {"url", "sha256"} or not re.fullmatch(r"[0-9a-f]{64}", source["sha256"]):
            raise ValueError("Invalid source pin")
        https_url(source["url"])
        reviewed, deadline = date.fromisoformat(entry["reviewed"]), date.fromisoformat(entry["reviewBy"])
        if not reviewed < deadline or (deadline - reviewed).days > 90 or reviewed > today:
            raise ValueError("Override requires a valid review window of at most 90 days")
        for field in ("advisories", "validation"):
            if not isinstance(entry[field], list) or not 0 < len(entry[field]) <= 100:
                raise ValueError("Override requires advisories and validation notes")
        result.append({
            "package": name, "fixedVersion": entry["fixedVersion"],
            "advisories": [https_url(value) for value in entry["advisories"]],
            "reviewed": reviewed.isoformat(), "reviewBy": deadline.isoformat(),
            "reviewDue": today >= deadline,
            "reason": text(entry["reason"]), "removeWhen": text(entry["removeWhen"]),
            "validation": [text(value) for value in entry["validation"]],
        })
    return result


def locked_input(lock, name):
    nodes, root = lock["nodes"], lock["root"]
    if not isinstance(nodes, dict) or not isinstance(root, str) or not isinstance(nodes.get(root), dict):
        raise ValueError("Invalid lock nodes")
    def follow(node, names, seen):
        if not names:
            return node
        key = (node, tuple(names))
        if key in seen or len(seen) >= 100:
            raise ValueError("Cyclic or excessive lock follows")
        if not isinstance(nodes[node], dict) or not isinstance(nodes[node].get("inputs"), dict):
            raise ValueError("Invalid lock inputs")
        ref = nodes[node]["inputs"][names[0]]
        seen = seen | {key}
        if isinstance(ref, str):
            next_node = ref
        elif isinstance(ref, list) and all(isinstance(part, str) for part in ref):
            # Resolve follows relative to the root, as specified by flake locks.
            next_node = follow(root, ref, seen)
        else:
            raise ValueError("Invalid lock reference")
        return follow(next_node, names[1:], seen)
    if name not in nodes[root].get("inputs", {}):
        return None
    resolved = nodes[follow(root, [name], set())]
    if not isinstance(resolved, dict) or not isinstance(resolved.get("locked", {}), dict):
        raise ValueError("Invalid locked node")
    return resolved.get("locked", {})


def report(lock, manifest, today, max_age_days):
    if not isinstance(lock, dict) or type(lock.get("version")) is not int or lock["version"] != 7:
        raise ValueError("Unsupported flake lock schema")
    pins = []
    for name in INPUTS:
        locked = locked_input(lock, name)
        if locked is None:
            continue
        modified, revision = locked.get("lastModified"), locked.get("rev")
        if type(modified) is int and modified >= 0:
            age = (today - datetime.fromtimestamp(modified, timezone.utc).date()).days
        else:
            age = None
        # Never include source URLs, local paths, other nodes or private inputs.
        pins.append({"input": name,
                     "revision": revision if isinstance(revision, str) and re.fullmatch(r"[0-9a-f]{40,64}", revision) else None,
                     "ageDays": age,
                     "reviewDue": age is None or age < 0 or age > max_age_days})
    overrides = override_report(manifest, today)
    return {"version": 1, "asOf": today.isoformat(), "maxPinAgeDays": max_age_days,
            "inputs": pins, "overrides": overrides,
            "reviewRequired": not pins or any(p["reviewDue"] for p in pins + overrides),
            "scope": "Pin age and available override catalog only; activation is not evaluated. No CVE scan or deployment verification."}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lock", type=Path, default=Path("flake.lock"))
    parser.add_argument("--overrides", type=Path, default=ROOT / "security/overrides.json")
    parser.add_argument("--max-age-days", type=int, default=30)
    args = parser.parse_args()
    try:
        if not 1 <= args.max_age_days <= 365:
            raise ValueError("Invalid pin age policy")
        result = report(load_json(args.lock), load_json(args.overrides), datetime.now(timezone.utc).date(), args.max_age_days)
        print(json.dumps(result, indent=2))
        return 1 if result["reviewRequired"] else 0
    except (OSError, ValueError, TypeError, KeyError, OverflowError, RecursionError):
        print("Dependency report failed: invalid or unreadable input (contents withheld)", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
