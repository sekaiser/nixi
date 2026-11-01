#!/usr/bin/env python3
"""Serial, bounded Janet contracts in a synthetic consumer/home/store (CI only)."""
import argparse
import os
import resource
from pathlib import Path
import sys
import tempfile

from run_cli_tests import run_isolated

ROOT = Path(__file__).resolve().parents[1]
SUITES = ("unit", "cli", "utm-cli")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("suites", nargs="*", metavar="SUITE")
    args = parser.parse_args()
    if any(suite not in SUITES for suite in args.suites):
        parser.error("suite must be unit, cli or utm-cli")
    soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    resource.setrlimit(resource.RLIMIT_NOFILE, (min(soft, 256), hard))
    for suite in args.suites or SUITES:
        with tempfile.TemporaryDirectory(prefix="nixi-contract-") as directory:
            root = Path(directory)
            env = {key: value for key, value in os.environ.items() if key in {
                "PATH", "JANET_PATH", "JANET_TREE", "HEY_PROCESS_SUPERVISOR",
                "HEY_RUNTIME_PYTHON", "NIX_SSL_CERT_FILE", "SSL_CERT_FILE", "TMPDIR"}}
            env.update(HOME=str(root / "home"), DOTFILES_HOME=str(ROOT / "checks/fixtures/cli-host"),
                       HEY_HOST="laptop", HEY_USER="alice", HEY_THEME="alucard", LANG="C.UTF-8",
                       NIX_REMOTE=str(root / "nix-store"),
                       NIX_CONFIG="experimental-features = nix-command flakes\n")
            for name in ("BIN", "CONFIG", "DATA", "CACHE", "STATE"):
                env[f"XDG_{name}_HOME"] = str(root / name.lower())
                (root / name.lower()).mkdir()
            env["XDG_RUNTIME_DIR"] = str(root / "runtime")
            (root / "runtime").mkdir()
            Path(env["HOME"]).mkdir()
            profiles = root / "state/nix/profiles"
            profiles.mkdir(parents=True)
            (profiles / "profile-1-link").mkdir()
            (profiles / "profile").symlink_to("profile-1-link")
            if fixture := os.environ.get("NIXI_COMMAND_FIXTURE"):
                metadata = root / "data/hey"
                metadata.mkdir()
                (metadata / "commands.json").write_bytes(Path(fixture).read_bytes())
            # Contract suites test command wiring, never the developer/runner's
            # actual processes, agents, SSH connections or VM inventory.
            mocks = root / "mock-bin"
            mocks.mkdir()
            for command in ("ps", "lsof", "ssh", "utmctl", "kill"):
                executable = mocks / command
                executable.write_text("#!/bin/sh\nexit " + ("1" if command == "lsof" else "0") + "\n")
                executable.chmod(0o700)
            env["PATH"] = str(mocks) + os.pathsep + env.get("PATH", "")
            status, output, failure = run_isolated([str(ROOT / "bin/hey"), "check", suite],
                                                    timeout=300, env=env, cwd=env["DOTFILES_HOME"])
            print(output, end="", flush=True)
            if failure:
                print(f"{suite}: {failure}", file=sys.stderr)
            if status:
                return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
