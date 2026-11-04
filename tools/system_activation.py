"""Activate an already-built local system; never evaluate, build or fetch a flake."""
import argparse
from contextlib import contextmanager
import fcntl
import os
from pathlib import Path
import pwd
import re
import signal
import stat
import subprocess
import sys


class ActivationError(Exception):
    def __init__(self, message, status=1):
        super().__init__(message)
        self.status = status


def activation_environment():
    root = pwd.getpwuid(0)
    environment = {
        "HOME": root.pw_dir, "USER": root.pw_name, "LOGNAME": root.pw_name,
        "PATH": "/run/current-system/sw/bin:/usr/bin:/bin:/usr/sbin:/sbin",
        "LANG": "C", "LC_ALL": "C", "NIX_REMOTE": "daemon",
        "NIX_USER_CONF_FILES": "/dev/null",
    }
    # sudo supplies this identity; never forward the caller's build environment.
    if name := os.environ.get("SUDO_USER"):
        try:
            user = pwd.getpwnam(name)
            if (str(user.pw_uid) == os.environ.get("SUDO_UID")
                    and str(user.pw_gid) == os.environ.get("SUDO_GID")):
                environment.update(SUDO_USER=name, SUDO_UID=str(user.pw_uid), SUDO_GID=str(user.pw_gid))
        except KeyError:
            pass
    return environment


class Activation:
    # Alternate paths/runner are for synthetic tests, not exposed by the CLI.
    def __init__(self, system, nix_env, nix_store, *, store="/nix/store",
                 profile="/nix/var/nix/profiles/system", running="/run/current-system",
                 owner=0, runner=None):
        self.system = system
        self.store, self.profile, self.running = map(Path, (store, profile, running))
        self.owner = owner
        self.nix_env, self.nix_store = nix_env, nix_store
        self.environment = activation_environment()
        self.runner = runner
        self.child = None
        self.interrupted = 0

    def output(self, value):
        path = Path(value)
        if (str(path) != value or path.parent != self.store
                or not re.fullmatch(r"[0-9abcdfghijklmnpqrsvwxyz]{32}-[A-Za-z0-9+._?=-]+", path.name)
                or path.name.endswith(".drv") or path.resolve(strict=True) != path):
            raise ActivationError("Expected a canonical, realized local store output")
        info = path.stat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != self.owner or info.st_mode & 0o022:
            raise ActivationError("System output must be a protected store directory")
        return path

    def protected_file(self, value, executable=False):
        path = Path(value).resolve(strict=True)
        try:
            relative = path.relative_to(self.store)
        except ValueError:
            raise ActivationError("Activation executable escapes the local store") from None
        self.output(str(self.store / relative.parts[0]))
        for directory in path.parents:
            if directory == self.store:
                break
            info = directory.stat()
            if info.st_uid != self.owner or info.st_mode & 0o022:
                raise ActivationError("Activation executable has an unprotected ancestor")
        info = path.stat()
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != self.owner or info.st_mode & 0o022
                or (executable and not info.st_mode & 0o111)):
            raise ActivationError("Activation executable is not a protected executable file")
        return str(path)

    def executable(self, value):
        return self.protected_file(value, executable=True)

    def pinned_tool(self, value, name):
        """Validate a fixed Nix tool without losing its multicall alias name.

        The final target and every alias hop must stay in protected store
        outputs. Never retain an arbitrary mutable path merely because its
        current realpath happens to point back into the store.
        """
        path = Path(value)
        try:
            relative = path.relative_to(self.store)
        except ValueError:
            raise ActivationError("Pinned tool must use a canonical store alias") from None
        if str(path) != value or len(relative.parts) != 3 or relative.parts[1:] != ("bin", name):
            raise ActivationError("Pinned tool must use its fixed bin alias")
        current, pending, links = self.store, list(relative.parts), 0
        while pending:
            part = pending.pop(0)
            if part == "..":
                if current == self.store:
                    raise ActivationError("Pinned tool alias escapes the local store")
                current = current.parent
                continue
            child = current / part
            if current == self.store:
                self.output(str(child))
            info = child.lstat()
            if info.st_uid != self.owner:
                raise ActivationError("Pinned tool alias is not protected")
            if stat.S_ISLNK(info.st_mode):
                links += 1
                if links > 40:
                    raise ActivationError("Too many pinned tool aliases")
                target = child.readlink()
                if target.is_absolute():
                    try:
                        target = target.relative_to(self.store)
                    except ValueError:
                        raise ActivationError("Pinned tool alias escapes the local store") from None
                    current = self.store
                pending = list(target.parts) + pending
                continue
            if info.st_mode & 0o022:
                raise ActivationError("Pinned tool alias has an unprotected path")
            if pending:
                if not stat.S_ISDIR(info.st_mode):
                    raise ActivationError("Pinned tool alias parent is not a directory")
                current = child
            else:
                self.executable(str(child))
                return str(path)
        raise ActivationError("Pinned tool alias does not name an executable")

    def selected(self):
        return self.output(str(self.profile.resolve(strict=True)))

    def current(self):
        return self.output(str(self.running.resolve(strict=True)))

    def system_config(self, output):
        metadata = output / "systemConfig"
        if self.system == "Darwin" and os.path.lexists(metadata):
            with open(self.protected_file(metadata), "rb") as incoming:
                data = incoming.read(4097)
            if len(data) > 4096:
                raise ActivationError("Invalid Darwin systemConfig metadata")
            return self.output(data.decode("utf-8").strip())
        return output

    def activator(self, output):
        if self.system == "Darwin":
            legacy = output / "activate-user"
            if legacy.exists() and os.access(legacy, os.X_OK):
                with open(self.executable(legacy), "rb") as incoming:
                    if b"# nix-darwin: deprecated" not in incoming.read(4096):
                        raise ActivationError("Legacy activate-user needs a separately reviewed native activation procedure")
            return self.executable(output / "activate")
        return self.executable(output / "bin/switch-to-configuration")

    def run(self, command):
        if self.interrupted:
            raise ActivationError("System activation interrupted", 128 + self.interrupted)
        if self.runner:
            status = self.runner(list(map(str, command)), self.environment)
        else:
            # Foreground stdin/stdout/stderr stay attached for activation tools.
            self.child = subprocess.Popen(list(map(str, command)), env=self.environment, cwd="/")
            try:
                if self.interrupted:
                    self.child.send_signal(self.interrupted)
                status = self.child.wait()
            finally:
                self.child = None
        if self.interrupted:
            raise ActivationError("System activation interrupted", 128 + self.interrupted)
        if status:
            raise ActivationError("System activation command failed", status if status > 0 else 128 - status)

    def signal(self, number, _frame):
        self.interrupted = number
        if self.child is not None and self.child.poll() is None:
            self.child.send_signal(number)

    @contextmanager
    def locked(self):
        directory = self.profile.parent
        info = directory.stat()
        if directory.resolve() != directory or info.st_uid != self.owner or info.st_mode & 0o022:
            raise ActivationError("System profile directory is not protected")
        fd = os.open(directory / ".nixi-activation.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != self.owner or stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1:
                raise ActivationError("System activation lock is not protected")
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise ActivationError("Another Nixi system activation is in progress") from None
            yield
        finally:
            os.close(fd)

    def activation_command(self, output, action):
        program = self.activator(output)
        return [program] if self.system == "Darwin" else [program, action]

    def recover(self, action, candidate, selected, running, activation_attempted):
        permitted_profiles = (selected, candidate) if action in ("switch", "boot") else (selected,)
        if self.selected() not in permitted_profiles or self.current() not in (running, self.system_config(candidate)):
            raise ActivationError("Concurrent profile change; refusing to overwrite it during recovery")
        if self.selected() != selected:
            self.run([self.nix_env, "--profile", str(self.profile), "--set", str(selected)])
        if activation_attempted:
            if action in ("switch", "test", "activate"):
                self.run(self.activation_command(running, "test"))
            if self.system == "Linux" and action in ("switch", "boot"):
                self.run(self.activation_command(selected, "boot"))
        if self.selected() != selected or self.current() != running:
            raise ActivationError("Recovery did not converge; manual recovery is required")

    def apply(self, action, candidate, expected_profile, expected_running):
        allowed = {"switch", "activate"} if self.system == "Darwin" else {"switch", "boot", "test", "dry-activate"}
        if self.system not in ("Darwin", "Linux") or action not in allowed:
            raise ActivationError("Unsupported local system activation action")
        candidate, selected, running = map(self.output, (candidate, expected_profile, expected_running))
        self.nix_env = self.pinned_tool(self.nix_env, "nix-env")
        self.nix_store = self.pinned_tool(self.nix_store, "nix-store")
        for output in {candidate, selected, running}:
            self.activator(output)  # Validate recovery paths before changing anything.
        desired_running = self.system_config(candidate) if action in ("switch", "test", "activate") else running
        with self.locked():
            if self.selected() != selected or self.current() != running:
                raise ActivationError("System changed since build planning; retry with a fresh checkpoint")
            self.run([self.nix_store, "--check-validity", *map(str, sorted({candidate, selected, running}))])
            if self.selected() != selected or self.current() != running:
                raise ActivationError("System changed since build planning; retry with a fresh checkpoint")
            profile_attempted = activation_attempted = False
            try:
                if action in ("switch", "boot"):
                    profile_attempted = True
                    self.run([self.nix_env, "--profile", str(self.profile), "--set", str(candidate)])
                    if self.selected() != candidate:
                        raise ActivationError("System profile did not select the candidate")
                desired_profile = candidate if action in ("switch", "boot") else selected
                if self.selected() != desired_profile or self.current() != running:
                    raise ActivationError("System changed before activation")
                activation_attempted = True
                self.run(self.activation_command(candidate, action))
                if self.selected() != desired_profile or self.current() != desired_running:
                    raise ActivationError("System activation did not converge")
            except (ActivationError, OSError) as error:
                original = error if isinstance(error, ActivationError) else ActivationError("System activation could not execute")
                if action != "dry-activate" and (profile_attempted or activation_attempted):
                    self.interrupted = 0
                    try:
                        self.recover(action, candidate, selected, running, activation_attempted)
                    except (ActivationError, OSError):
                        raise ActivationError("Activation failed and recovery was incomplete; inspect the fixed checkpoint before manual recovery", original.status) from None
                    raise ActivationError("Activation failed; checkpoint outputs restored (application data is not rolled back)", original.status) from None
                raise original


def main(system, nix_env, nix_store):
    parser = argparse.ArgumentParser(description=__doc__)
    for option in ("action", "candidate", "expected-profile", "expected-running"):
        parser.add_argument("--" + option, required=True)
    args = parser.parse_args()
    if os.geteuid() != 0:
        parser.exit(1, "System activation requires root; build with the normal user first\n")
    activation = Activation(system, nix_env, nix_store)
    previous = {number: signal.signal(number, activation.signal) for number in (signal.SIGINT, signal.SIGTERM)}
    try:
        activation.apply(args.action, args.candidate, args.expected_profile, args.expected_running)
        return 0
    except ActivationError as error:
        print(str(error), file=sys.stderr)
        return min(error.status, 255)
    except (OSError, UnicodeError, ValueError):
        print("System activation input or protected path validation failed", file=sys.stderr)
        return 1
    finally:
        for number, handler in previous.items():
            signal.signal(number, handler)
