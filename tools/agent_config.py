"""Inspect agent configuration structurally; emit statuses, never config values."""
import argparse
import json
import sys
import tomllib

from runtime_input import deadline, read_regular


def entry_status(entries, name):
    if not isinstance(entries, dict):
        return "malformed"
    if name not in entries:
        return "missing"
    entry = entries[name]
    if not isinstance(entry, dict) or not entry or type(entry.get("enabled", True)) is not bool:
        return "malformed"
    return "configured" if entry.get("enabled", True) else "disabled"


def inspect(kind, path, expected):
    data = read_regular(path).decode("utf-8")
    if kind == "codex":
        config = tomllib.loads(data)
        result = {}
        for key in ("plugins", "mcpServers"):
            names = expected.get(key, [])
            if not isinstance(names, list) or not all(isinstance(name, str) for name in names):
                raise ValueError("Invalid agent manifest")
            entries = config.get("plugins" if key == "plugins" else "mcp_servers", {})
            result[key] = {name: entry_status(entries, name) for name in names}
        return result
    import yaml
    config = yaml.safe_load(data)
    if not isinstance(config, dict):
        raise ValueError("Expected a configuration object")
    roles = config.get("modelRoles", {})
    expected_roles = expected.get("modelRoles", {})
    if not isinstance(roles, dict) or not isinstance(expected_roles, dict):
        raise ValueError("Expected modelRoles objects")
    return {"modelRoles": {role: ("missing" if role not in roles else
                                 "configured" if roles[role] == model else "mismatched")
                           for role, model in expected_roles.items()}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("kind", choices=["codex", "omp"])
    parser.add_argument("path")
    parser.add_argument("expected", help="JSON of non-secret expected entries")
    args = parser.parse_args()
    try:
        with deadline(5):
            expected = json.loads(args.expected)
            if not isinstance(expected, dict):
                raise ValueError("Expected a manifest object")
            result = inspect(args.kind, args.path, expected)
        print(json.dumps(result))
        return 0
    except Exception:
        # Parser exceptions can contain lines from the configuration, including
        # credentials. Do not forward their messages, input or a traceback.
        print("Agent configuration is missing, unreadable, malformed or exceeds its input limits (1 MiB, five seconds)", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
