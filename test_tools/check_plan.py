"""Validate explicit CI coverage; print native build names without executing Nix."""
import argparse
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
CATEGORIES = {"native", "evaluation", "vm"}
REQUIRED_NATIVE = {"agent-memory", "publication-boundary", "runtime-inputs", "process-supervisor",
                   "user-file-installation", "cli-contracts", "ci-check-plan", "system-activation", "dependency-coverage"}


def names(values):
    if not isinstance(values, list) or not all(
            isinstance(name, str) and re.fullmatch(r"[a-z][a-z0-9-]*", name) for name in values):
        raise ValueError("Check names must be a list of simple identifiers")
    if len(set(values)) != len(values):
        raise ValueError("Duplicate check names")
    return set(values)


def plan(policy, declared, available, required=()):
    if (not isinstance(policy, dict) or set(policy) != CATEGORIES | {"version"}
            or type(policy["version"]) is not int or policy["version"] != 1):
        raise ValueError("Unsupported check policy schema")
    categories = {key: names(policy[key]) for key in CATEGORIES}
    classified = set().union(*categories.values())
    if sum(map(len, categories.values())) != len(classified):
        raise ValueError("Each check must have exactly one classification")
    declared, available = names(declared), names(available)
    if classified != declared:
        raise ValueError("Check policy differs from definitions: unclassified="
                         + ",".join(sorted(declared - classified)) + "; stale="
                         + ",".join(sorted(classified - declared)))
    if not available or not available <= declared:
        raise ValueError("Platform check names must be a nonempty subset of declared checks")
    selected = categories["native"] & available
    if not selected or not set(required) <= selected:
        raise ValueError("Native check coverage is empty or missing required checks: "
                         + ",".join(sorted(set(required) - selected)))
    return sorted(selected)


def declared_checks(root):
    # Match the framework's flat check-definition discovery, excluding fixtures
    # and underscore-prefixed helpers. Platform filtering comes from Nix itself.
    return sorted(path.stem for path in (root / "checks").glob("*.nix")
                  if path.is_file() and not path.name.startswith("_")
                  and path.name not in {"default.nix", "flake.nix"})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("available", type=Path,
                        help="JSON array from nix eval .#checks.SYSTEM --apply builtins.attrNames")
    args = parser.parse_args()
    try:
        policy = json.loads((ROOT / "test_tools/check-policy.json").read_text())
        builds = plan(policy, declared_checks(ROOT), json.loads(args.available.read_text()), REQUIRED_NATIVE)
    except (OSError, ValueError) as error:
        print(f"CI check coverage refused: {error}", file=sys.stderr)
        return 1
    for name in builds:
        print(name)
    return 0


if __name__ == "__main__":
    sys.exit(main())
