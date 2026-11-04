"""Opt-in runtime receipts and explicit retirement, entirely as the recipient.

Receipts contain private file fingerprints, never source paths or file contents.
They are provenance, not evidence that a credential is unused or revoked.
Cooperating installs/retirements share a lock; independent writers must stop.
"""
from contextlib import contextmanager
import fcntl
import hashlib
import hmac
import io
import json
import os
from pathlib import Path
import re
import secrets
import stat

from runtime_input import read_bounded


FIELDS = ("dev", "ino", "uid", "gid", "mode", "size", "mtime_ns", "ctime_ns")


def canonical(value):
    value = os.fspath(value)
    if (not isinstance(value, str) or not value.startswith("/")
            or any(p in ("", ".", "..") for p in value.split("/")[1:])
            or "\\" in value or any(ord(c) < 32 or ord(c) == 127 for c in value)
            or value == "/nix/store" or value.startswith("/nix/store/")):
        raise ValueError("Expected a canonical absolute runtime filename")
    return Path(value)


def recipient_only():
    if os.geteuid() == 0:
        raise PermissionError("Run lifecycle operations as the recipient, never root")


def check_directory(info, final=False):
    sticky_root = info.st_uid == 0 and info.st_mode & stat.S_ISVTX
    if (not stat.S_ISDIR(info.st_mode) or info.st_uid not in (0, os.geteuid())
            or (info.st_mode & 0o022 and not sticky_root)
            or (final and (info.st_uid != os.geteuid() or info.st_mode & 0o022))):
        raise PermissionError("Untrusted runtime directory")


@contextmanager
def parent(path, create=False):
    """Pin every directory; no symlinks, chmod/chown or root destination access."""
    recipient_only()
    path = canonical(path)
    directory = os.open("/", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        check_directory(os.fstat(directory))
        for part in path.parts[1:-1]:
            if create:
                try:
                    os.mkdir(part, 0o700, dir_fd=directory)
                except FileExistsError:
                    pass
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=directory)
            os.close(directory)
            directory = child
            check_directory(os.fstat(directory))
        check_directory(os.fstat(directory), final=True)
        yield directory, path.name
    finally:
        os.close(directory)


def private_file(info):
    if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid()
            or stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1):
        raise PermissionError("Expected a private, singly linked recipient-owned file")


def identity(info):
    return dict(zip(FIELDS, (info.st_dev, info.st_ino, info.st_uid, info.st_gid,
                            stat.S_IMODE(info.st_mode), info.st_size,
                            info.st_mtime_ns, info.st_ctime_ns)))


def snapshot(directory, name, limit=1024 * 1024):
    before = os.stat(name, dir_fd=directory, follow_symlinks=False)
    private_file(before)
    fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
    try:
        actual = os.fstat(fd)
        private_file(actual)
        if identity(actual) != identity(before):
            raise ValueError("File changed during opening")
        with os.fdopen(fd, "rb", closefd=False) as stream:
            data = read_bounded(stream, limit)
        if identity(os.fstat(fd)) != identity(actual):
            raise ValueError("File changed during reading")
        return identity(actual), data
    finally:
        os.close(fd)


def load(directory, name):
    _, data = snapshot(directory, name, 16384)
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("Duplicate receipt key")
            result[key] = value
        return result
    record = json.loads(data, object_pairs_hook=unique)
    if (not isinstance(record, dict)
            or set(record) != {"version", "destination", "identity", "sha256", "token"}
            or type(record["version"]) is not int or record["version"] != 1
            or not isinstance(record["identity"], dict)
            or set(record["identity"]) != set(FIELDS)
            or any(type(v) is not int or v < 0 for v in record["identity"].values())
            or record["identity"]["uid"] != os.geteuid()
            or record["identity"]["mode"] != 0o600
            or any(not isinstance(record[k], str) or re.fullmatch(r"[0-9a-f]{64}", record[k]) is None
                   for k in ("sha256", "token"))):
        raise ValueError("Unsupported receipt")
    canonical(record["destination"])
    return record


@contextmanager
def locked(receipt, create=False):
    with parent(receipt, create=create) as (directory, name):
        flags = os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK
        if create:
            flags |= os.O_CREAT
        fd = os.open(name + ".lock", flags, 0o600, dir_fd=directory)
        try:
            private_file(os.fstat(fd))
            fcntl.flock(fd, fcntl.LOCK_EX)
            yield directory, name
        finally:
            os.close(fd)


def quarantine(record):
    return ".nixi-retire-" + record["token"]


def exists(directory, name):
    try:
        os.stat(name, dir_fd=directory, follow_symlinks=False)
        return True
    except FileNotFoundError:
        return False


def inspect_target(directory, name, record, captured=False):
    try:
        actual, data = snapshot(directory, name)
    except FileNotFoundError:
        return "missing"
    except (OSError, ValueError):
        return "unsafe"
    expected = record["identity"]
    # Rename changes ctime. Before capture require the exact recorded metadata;
    # afterwards require the same inode, other metadata and bounded file digest.
    fields = [field for field in FIELDS if not captured or field != "ctime_ns"]
    if (any(actual[field] != expected[field] for field in fields)
            or not hmac.compare_digest(hashlib.sha256(data).hexdigest(), record["sha256"])):
        return "changed"
    return "ready"


def install_tracked(incoming, destination, receipt, mode, replace):
    recipient_only()
    destination, receipt = canonical(destination), canonical(receipt)
    if mode != 0o600 or str(destination) in (str(receipt), str(receipt) + ".lock"):
        raise ValueError("Tracking requires a distinct receipt and a private destination")
    with locked(receipt, create=True) as (receipts, receipt_name):
        previous = load(receipts, receipt_name) if exists(receipts, receipt_name) else None
        if previous is not None and previous["destination"] != str(destination):
            raise ValueError("Receipt belongs to a different destination")
        with parent(destination, create=True) as (directory, name):
            if previous is not None and exists(directory, quarantine(previous)):
                raise ValueError("Restore an interrupted retirement before reinstalling")
            replace(incoming, directory, name, mode)
            info, data = snapshot(directory, name)
            record = {"version": 1, "destination": str(destination), "identity": info,
                      "sha256": hashlib.sha256(data).hexdigest(), "token": secrets.token_hex(32)}
            replace(io.BytesIO(json.dumps(record, sort_keys=True).encode()), receipts, receipt_name, 0o600)


def preview(receipt):
    with locked(receipt) as (receipts, receipt_name):
        record = load(receipts, receipt_name)
        destination = canonical(record["destination"])
        try:
            with parent(destination) as (directory, name):
                pending = exists(directory, quarantine(record))
                status = "pending" if pending else inspect_target(directory, name, record)
        except FileNotFoundError:
            status = "missing"
        result = {"status": status, "destination": str(destination)}
        if status == "ready":
            result["reviewToken"] = record["token"]
        if status == "pending":
            result["quarantine"] = str(destination.parent / quarantine(record))
        return result


def restore_payload(directory, name, holding):
    # Atomic no-clobber restoration. Never replace a file that appeared while
    # retirement was interrupted. Unsupported types remain in private quarantine.
    os.link("payload", name, src_dir_fd=holding, dst_dir_fd=directory, follow_symlinks=False)
    os.unlink("payload", dir_fd=holding)


@contextmanager
def holding_directory(directory, record):
    fd = os.open(quarantine(record), os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=directory)
    try:
        info = os.fstat(fd)
        if info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) != 0o700:
            raise PermissionError("Unsafe retirement quarantine")
        yield fd
    finally:
        os.close(fd)


def retire(receipt, token):
    with locked(receipt) as (receipts, receipt_name):
        record = load(receipts, receipt_name)
        if not isinstance(token, str) or not hmac.compare_digest(token, record["token"]):
            raise ValueError("Review token is stale or incorrect")
        destination = canonical(record["destination"])
        with parent(destination) as (directory, name):
            if exists(directory, quarantine(record)):
                raise ValueError("Interrupted retirement requires explicit restoration")
            status = inspect_target(directory, name, record)
            if status == "missing":
                return {"status": "missing", "destination": str(destination)}
            if status != "ready":
                raise ValueError("Recorded file no longer matches; preserved")
            os.mkdir(quarantine(record), 0o700, dir_fd=directory)
            captured = False
            with holding_directory(directory, record) as holding:
                try:
                    os.rename(name, "payload", src_dir_fd=directory, dst_dir_fd=holding)
                    captured = True
                    if inspect_target(holding, "payload", record, captured=True) != "ready":
                        raise ValueError("File changed during capture; preserved")
                    os.unlink("payload", dir_fd=holding)
                    captured = False
                except BaseException:
                    if captured:
                        try:
                            restore_payload(directory, name, holding)
                            captured = False
                        except OSError:
                            pass  # Retain recoverable data, never clobber a new target.
                    if not captured:
                        os.rmdir(quarantine(record), dir_fd=directory)
                    raise
            os.rmdir(quarantine(record), dir_fd=directory)
            # Retain the private receipt and lock as provenance, not active state.
            return {"status": "retired", "destination": str(destination)}


def restore(receipt):
    with locked(receipt) as (receipts, receipt_name):
        record = load(receipts, receipt_name)
        destination = canonical(record["destination"])
        with parent(destination) as (directory, name):
            if not exists(directory, quarantine(record)):
                return {"status": "nothing-pending", "destination": str(destination)}
            with holding_directory(directory, record) as holding:
                if exists(holding, "payload"):
                    restore_payload(directory, name, holding)
                    status = "restored"
                else:
                    status = "no-payload"
            os.rmdir(quarantine(record), dir_fd=directory)
            return {"status": status, "destination": str(destination)}
