"""Merge declarative OMP defaults into private, writable user settings.

Run as the recipient, never root. Do not follow mutable config symlinks; readable
legacy Nix-store links are migrated with a private backup. No config values log.
"""
import argparse
import fcntl
import json
import os
from pathlib import Path
import stat
import tempfile

import yaml

LIMIT = 1024 * 1024


class Loader(yaml.SafeLoader):
    def compose_node(self, parent, index):
        self.nodes = getattr(self, "nodes", 0) + 1
        self.depth = getattr(self, "depth", 0) + 1
        try:
            if self.nodes > 10000 or self.depth > 32 or self.check_event(yaml.AliasEvent):
                raise ValueError("Configuration exceeds parser limits")
            return super().compose_node(parent, index)
        finally:
            self.depth -= 1

    def construct_mapping(self, node, deep=False):
        result = {}
        for key_node, value_node in node.value:
            key = self.construct_object(key_node, deep=deep)
            if not isinstance(key, str) or key in result:
                raise ValueError("Duplicate/non-string configuration key")
            result[key] = self.construct_object(value_node, deep=deep)
        return result


def read(path, private=True):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or (private and info.st_nlink != 1):
            raise ValueError("Expected an unlinked regular config file")
        if private and (info.st_uid != os.getuid() or info.st_mode & 0o077):
            raise ValueError("Runtime config must be private and user-owned")
        content = stream.read(LIMIT + 1)
        if len(content) > LIMIT:
            raise ValueError("Configuration exceeds size limit")
        return content


def directory(path):
    if not path.is_absolute() or ".." in path.parts or str(path).startswith("/nix/store/"):
        raise ValueError("Invalid runtime directory")
    for parent in [*reversed(path.parents), path]:
        if parent.is_symlink():
            raise ValueError("Runtime directories must not traverse symlinks")
        if parent.exists():
            info = parent.stat()
            if not stat.S_ISDIR(info.st_mode) or info.st_uid not in (0, os.getuid()):
                raise ValueError("Untrusted runtime directory")
            if info.st_mode & 0o022 and not (info.st_uid == 0 and info.st_mode & stat.S_ISVTX):
                raise ValueError("Runtime ancestors writable by others")
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    if path.stat().st_uid != os.getuid():
        raise ValueError("Repair runtime directory ownership first")


def atomic(path, data):
    fd, temporary = tempfile.mkstemp(prefix=".nixi-omp-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def leaves(data, prefix=()):
    for key, value in data.items():
        if isinstance(value, dict) and value:
            yield from leaves(value, (*prefix, key))
        else:
            yield (*prefix, key), value


def lookup(data, path):
    for key in path:
        if not isinstance(data, dict) or key not in data:
            return False, None
        data = data[key]
    return True, data


def merge(current, previous, defaults):
    # Retired declarations are removed only if the user has not changed them.
    new_paths = {path for path, _ in leaves(defaults)}
    for path, old in leaves(previous):
        found, value = lookup(current, path)
        if path not in new_paths and found and value == old:
            parent = current
            for key in path[:-1]:
                parent = parent[key]
            parent.pop(path[-1])
    for path, value in leaves(defaults):
        parent = current
        for key in path[:-1]:
            if key not in parent:
                parent[key] = {}
            if not isinstance(parent[key], dict):
                raise ValueError("Declared default conflicts with a user setting")
            parent = parent[key]
        parent[path[-1]] = value
    return current


def sync(defaults_path, config):
    if os.geteuid() == 0:
        raise ValueError("Run OMP config activation as the recipient, never root")
    defaults = yaml.load(read(defaults_path, private=False), Loader=Loader)
    if not isinstance(defaults, dict):
        raise ValueError("Expected declarative defaults object")
    directory(config.parent)
    metadata = config.with_name(config.name + ".nixi-managed.json")
    lock_path = config.with_name(config.name + ".nixi-lock")
    fd = os.open(lock_path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "a") as lock:
        info = os.fstat(lock.fileno())
        if info.st_uid != os.getuid() or not stat.S_ISREG(info.st_mode) or info.st_mode & 0o077 or info.st_nlink != 1:
            raise ValueError("Unsafe activation lock")
        fcntl.flock(lock, fcntl.LOCK_EX)
        legacy_link = None
        if config.is_symlink():
            if config.lstat().st_uid != os.getuid():
                raise ValueError("Repair config link ownership first")
            legacy_link = os.readlink(config)
            target = config.resolve(strict=True)
            if not str(target).startswith("/nix/store/"):
                raise ValueError("Refusing a non-store config symlink")
            original = read(target, private=False)
        else:
            original = read(config) if config.exists() else b""
        current = yaml.load(original, Loader=Loader) if original else {}
        if current is None:
            current = {}
        if not isinstance(current, dict):
            raise ValueError("Expected existing settings object")
        previous = json.loads(read(metadata)) if metadata.exists() or metadata.is_symlink() else {}
        if not isinstance(previous, dict):
            raise ValueError("Invalid managed-settings metadata")
        updated = yaml.safe_dump(merge(current, previous, defaults), sort_keys=False).encode()
        if legacy_link is not None:
            backup = config.with_name(config.name + ".before-nixi-migration")
            backup_fd = os.open(backup, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            with os.fdopen(backup_fd, "wb") as stream:
                stream.write(original)
                stream.flush()
                os.fsync(stream.fileno())
            if not config.is_symlink() or os.readlink(config) != legacy_link:
                raise ValueError("Configuration changed concurrently")
        elif (read(config) if config.exists() else b"") != original:
            raise ValueError("Configuration changed concurrently")
        if original != updated or legacy_link is not None:
            atomic(config, updated)
        atomic(metadata, json.dumps(defaults).encode())


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--defaults", type=Path, required=True)
    parser.add_argument("--config", type=Path, required=True)
    args = parser.parse_args()
    try:
        sync(args.defaults, args.config)
    except Exception:
        parser.exit(1, "OMP config sync failed: repair ownership/private permissions or an unreadable legacy store link first. Existing settings preserved; no values logged.\n")


if __name__ == "__main__":
    main()
