"""Open a trusted runtime source, then drop privileges before touching user paths.

The source can be root-readable; destination traversal and atomic replacement
must happen entirely as the recipient. No root chmod/chown of home directories.
"""
import argparse
from collections import deque
import grp
import os
from pathlib import Path
import pwd
import secrets
import stat
from runtime_input import deadline, read_bounded


def _check_source_directory(info):
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
        raise PermissionError("Privileged source directories must be root-owned and not group/world writable")


def _check_source_file(info, recipient_uid=None):
    if not stat.S_ISREG(info.st_mode):
        raise ValueError("Source must be a regular file")
    if recipient_uid is not None and (info.st_uid not in (0, recipient_uid) or info.st_mode & 0o022):
        raise PermissionError("Privileged source must be owned by root or the recipient and not group/world writable")


def _open_privileged_source(root_fd, source, recipient_uid):
    """Walk from a pinned root, following only links in protected directories.

    Absolute links restart at root_fd; relative links resolve from their parent.
    This supports secret-provider generation links without realpath/open races.
    The production caller always supplies the filesystem root; tests use a
    synthetic root and simulate directory ownership, never real privileges.
    """
    pending = deque(source.split("/"))
    directory = os.dup(root_fd)
    links = 0
    try:
        _check_source_directory(os.fstat(directory))
        while pending:
            part = pending.popleft()
            if part in ("", "."):
                continue
            info = os.stat(part, dir_fd=directory, follow_symlinks=False)
            if stat.S_ISLNK(info.st_mode):
                links += 1
                if links > 40:
                    raise ValueError("Too many source symlinks")
                target = os.readlink(part, dir_fd=directory)
                if target.startswith("/"):
                    restarted = os.dup(root_fd)
                    os.close(directory)
                    directory = restarted
                pending.extendleft(reversed(target.split("/")))
                continue
            if pending:
                child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=directory)
                os.close(directory)
                directory = child
                _check_source_directory(os.fstat(directory))
                continue
            # Reject known special files before opening; O_NONBLOCK also avoids
            # hanging if a concurrent provider replacement changes the type.
            _check_source_file(info, recipient_uid)
            fd = os.open(part, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
            try:
                actual = os.fstat(fd)
                _check_source_file(actual, recipient_uid)
                if (actual.st_dev, actual.st_ino) != (info.st_dev, info.st_ino):
                    raise ValueError("Source changed while opening; retry the installation")
            except BaseException:
                os.close(fd)
                raise
            return fd
        raise ValueError("Source must name a regular file")
    finally:
        os.close(directory)


def open_source(source, recipient_uid):
    source = os.fspath(source)
    if not os.path.isabs(source):
        raise ValueError("Source must be an absolute runtime path")
    if os.geteuid() == 0:
        root_fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            fd = _open_privileged_source(root_fd, source, recipient_uid)
        finally:
            os.close(root_fd)
    else:
        # Already unprivileged: normal filesystem access determines readability.
        _check_source_file(os.stat(source))
        fd = os.open(source, os.O_RDONLY | os.O_NONBLOCK)
        try:
            _check_source_file(os.fstat(fd))
        except BaseException:
            os.close(fd)
            raise
    return os.fdopen(fd, "rb")


def drop_privileges(user, group):
    account = pwd.getpwnam(user)
    gid = grp.getgrnam(group).gr_gid
    if os.geteuid() == 0:
        os.initgroups(user, gid)
        os.setgid(gid)
        os.setuid(account.pw_uid)
    if os.geteuid() != account.pw_uid or os.getegid() != gid:
        raise PermissionError("Cannot install as the requested user/group")


def replace_file(incoming, directory, name, mode):
    """Replace one file in an already checked, pinned directory."""
    if name in ("", ".", "..") or "/" in name:
        raise ValueError("Destination must be a single filename")
    temporary = None
    try:
        candidate = ".nixi-install-" + secrets.token_hex(16)
        fd = os.open(candidate, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600, dir_fd=directory)
        temporary = candidate
        with os.fdopen(fd, "wb") as outgoing:
            outgoing.write(read_bounded(incoming))
            os.fchmod(outgoing.fileno(), mode)
            outgoing.flush()
            os.fsync(outgoing.fileno())
        os.replace(temporary, name, src_dir_fd=directory, dst_dir_fd=directory)
        temporary = None
    finally:
        if temporary is not None:
            try:
                os.unlink(temporary, dir_fd=directory)
            except FileNotFoundError:
                pass


def root_destination(destination):
    """Open a host certificate's parent; root never follows user-owned paths."""
    destination = os.fspath(destination)
    if not os.path.isabs(destination) or any(part in ("", ".", "..") for part in destination.split("/")[1:]):
        raise ValueError("Host certificate destination must be a canonical absolute path")
    if os.geteuid() != 0:
        # An unprivileged invocation has no extra authority. Used by native
        # build-time tests too; still refuse a final directory symlink.
        Path(destination).parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        fd = os.open(Path(destination).parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        info = os.fstat(fd)
        if info.st_uid != os.geteuid() or info.st_mode & 0o022:
            os.close(fd)
            raise PermissionError("Destination directory is not protected")
        return fd
    directory = os.open("/", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        _check_source_directory(os.fstat(directory))
        for part in destination.split("/")[1:-1]:
            try:
                os.mkdir(part, mode=0o755, dir_fd=directory)
            except FileExistsError:
                pass
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=directory)
            os.close(directory)
            directory = child
            _check_source_directory(os.fstat(directory))
        result = directory
        directory = None
        return result
    finally:
        if directory is not None:
            os.close(directory)


def install(source, destination, user, group, mode):
    # Open only the explicitly configured source while privileged. Keeping this
    # descriptor avoids exposing the source path or a staging directory to users.
    recipient_uid = pwd.getpwnam(user).pw_uid
    with open_source(source, recipient_uid) as incoming:
        drop_privileges(user, group)
        os.umask(0o077)
        destination = Path(destination)
        destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        directory = os.open(destination.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            info = os.fstat(directory)
            if info.st_uid != os.geteuid() or info.st_mode & 0o022:
                raise PermissionError("Destination directory must be owned by the recipient and not group/world writable")
            replace_file(incoming, directory, destination.name, mode)
        finally:
            os.close(directory)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prepare-source-directory", metavar="PATH",
                        help="Prepare a protected provider directory as root; never chmod/chown existing paths")
    parser.add_argument("source", nargs="?")
    parser.add_argument("destination", nargs="?")
    parser.add_argument("user", nargs="?")
    parser.add_argument("group", nargs="?")
    parser.add_argument("mode", nargs="?", type=lambda value: int(value, 8), choices=[0o600, 0o644])
    args = parser.parse_args()
    values = (args.source, args.destination, args.user, args.group, args.mode)
    if args.prepare_source_directory is not None:
        if any(value is not None for value in values):
            parser.error("directory preparation cannot be combined with file installation")
        if not args.prepare_source_directory:
            parser.error("source directory must not be empty")
        if os.geteuid() != 0:
            parser.error("source directory preparation requires root")
        fd = root_destination(args.prepare_source_directory + "/.nixi-directory-check")
        os.close(fd)
        return
    if any(value is None for value in values):
        parser.error("file installation requires source, destination, user, group and mode")
    with deadline(45):
        install(args.source, args.destination, args.user, args.group, args.mode)


if __name__ == "__main__":
    main()
