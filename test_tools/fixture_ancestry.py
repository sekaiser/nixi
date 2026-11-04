"""Test-only host-ancestry model; never imported by a production helper.

Nix's user-namespace sandbox can expose an unmapped owner for '/'. In-process
fixtures model a trusted host outside their disposable root. All metadata at
the fixture root and below stays real. Subprocesses deliberately receive no
model; actual recipient CLI acceptance requires trustworthy real ancestry.
"""
from contextlib import contextmanager
import os
from pathlib import Path
import stat
from unittest.mock import patch


def actual_ancestry_trusted(root):
    """Inspect real pathname metadata before installing any fixture patches."""
    uid = os.geteuid()
    if uid == 0:
        return False
    try:
        for parent in [*Path(root).parents, Path(root)]:
            info = parent.stat(follow_symlinks=False)
            sticky_root = info.st_uid == 0 and info.st_mode & stat.S_ISVTX
            if (not stat.S_ISDIR(info.st_mode) or info.st_uid not in (0, uid)
                    or (info.st_mode & 0o022 and not sticky_root)):
                return False
        return True
    except OSError:
        return False


@contextmanager
def model_ancestor_fstat(root):
    """Change only strict ancestor directory owner/mode observations in-process.

    Match pinned directory identities, not path prefixes or every descriptor.
    Preserve inode/device and all file metadata; do not model the fixture itself.
    """
    outside = {(info.st_dev, info.st_ino) for parent in Path(root).parents
               for info in [parent.stat(follow_symlinks=False)]}
    real_fstat = os.fstat

    def observed(fd):
        info = real_fstat(fd)
        if stat.S_ISDIR(info.st_mode) and (info.st_dev, info.st_ino) in outside:
            values = list(info)
            values[0], values[4] = stat.S_IFDIR | 0o755, 0
            return os.stat_result(values, {name: getattr(info, name) for name in
                                          ("st_atime_ns", "st_mtime_ns", "st_ctime_ns")})
        return info

    with patch.object(os, "fstat", side_effect=observed):
        yield
