"""Synthetic system transactions; no root, live profiles, services or boot changes."""
import fcntl
import io
import os
from pathlib import Path
import pwd
import signal
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import system_activation as activation


class Transactions(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="nixi-activation-")
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name).resolve()
        self.store = self.root / "store"
        self.store.mkdir()
        self.outputs = []
        for number, label in enumerate(("candidate", "checkpoint", "other", "tools")):
            output = self.store / (str(number) * 32 + "-" + label)
            (output / "bin").mkdir(parents=True)
            for name in ("activate", "bin/switch-to-configuration", "bin/nix-env", "bin/nix-store"):
                path = output / name
                path.write_text("#!/bin/sh\nexit 0\n")
                path.chmod(0o555)
            (output / "systemConfig").write_text(str(output))
            self.outputs.append(output)
        self.candidate, self.checkpoint, self.other, self.tools = self.outputs
        self.profile = self.root / "profiles/system"
        self.profile.parent.mkdir()
        self.running = self.root / "running"
        self.link(self.profile, self.checkpoint)
        self.link(self.running, self.checkpoint)
        self.events = []
        self.fail_profile = self.fail_activation = self.fail_recovery = self.fail_validity = False
        self.concurrent = self.no_convergence = False

    def link(self, path, target):
        path.unlink(missing_ok=True)
        path.symlink_to(target)

    def driver(self, system="Linux", runner=True):
        return activation.Activation(system, str(self.tools / "bin/nix-env"), str(self.tools / "bin/nix-store"),
            store=self.store, profile=self.profile, running=self.running, owner=os.geteuid(),
            runner=self.run_command if runner else None)

    def run_command(self, command, environment):
        self.events.append(command)
        self.assertNotIn("NIX_CONFIG", environment)
        self.assertNotIn("SSH_AUTH_SOCK", environment)
        self.assertNotIn("DOTFILES_HOME", environment)
        # All child commands, including metadata queries, hold the root-side lock.
        with (self.profile.parent / ".nixi-activation.lock").open("rb") as incoming:
            with self.assertRaises(BlockingIOError):
                fcntl.flock(incoming.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        if command[0].endswith("/nix-store"):
            self.assertEqual(command[1], "--check-validity")
            return 7 if self.fail_validity else 0
        if command[0].endswith("/nix-env"):
            self.assertEqual(command[1:4], ["--profile", str(self.profile), "--set"])
            target = Path(command[4])
            self.link(self.profile, target)
            return 17 if self.fail_profile and target == self.candidate else 0
        output = Path(command[0]).parent
        if output.name == "bin":
            output = output.parent
        action = command[1] if len(command) > 1 else "activate"
        if output == self.checkpoint and self.fail_recovery:
            return 31
        if action in ("switch", "test", "activate") and not self.no_convergence:
            self.link(self.running, output)
        if output == self.candidate and self.fail_activation:
            if self.concurrent:
                self.link(self.profile, self.other)
            return 23
        return 0

    def apply(self, driver=None, action="switch"):
        (driver or self.driver()).apply(action, str(self.candidate), str(self.checkpoint), str(self.checkpoint))

    def test_switch_uses_only_fixed_commands_and_updates_both_observations(self):
        for system in ("Linux", "Darwin"):
            with self.subTest(system=system):
                self.setUp_state()
                self.apply(self.driver(system))
                self.assertEqual(self.profile.resolve(), self.candidate)
                self.assertEqual(self.running.resolve(), self.candidate)
                self.assertEqual(len(self.events), 3)
                self.assertFalse(any(word in command for command in self.events for word in ("build", "eval", "--flake", "--realise")))

    def setUp_state(self):
        self.link(self.profile, self.checkpoint)
        self.link(self.running, self.checkpoint)
        self.events.clear()

    def test_boot_changes_profile_without_switching_running_system(self):
        self.apply(action="boot")
        self.assertEqual(self.profile.resolve(), self.candidate)
        self.assertEqual(self.running.resolve(), self.checkpoint)
        self.assertEqual(self.events[-1][-1], "boot")

    def test_test_and_activate_keep_selected_profile(self):
        for system, action in (("Linux", "test"), ("Darwin", "activate")):
            with self.subTest(system=system):
                self.setUp_state()
                self.apply(self.driver(system), action)
                self.assertEqual(self.profile.resolve(), self.checkpoint)
                self.assertEqual(self.running.resolve(), self.candidate)
                self.assertEqual(len(self.events), 2)

    def test_dry_activate_never_switches_or_recovers_a_real_system(self):
        for failing in (False, True):
            self.events.clear()
            self.fail_activation = failing
            if failing:
                with self.assertRaises(activation.ActivationError):
                    self.apply(action="dry-activate")
            else:
                self.apply(action="dry-activate")
            self.assertEqual(self.profile.resolve(), self.checkpoint)
            self.assertEqual(self.running.resolve(), self.checkpoint)
            self.assertEqual(self.events[-1][-1], "dry-activate")
            self.assertEqual(len(self.events), 2)

    def test_changed_profile_or_running_checkpoint_fails_before_commands(self):
        for path in (self.profile, self.running):
            self.setUp_state()
            self.link(path, self.other)
            with self.assertRaisesRegex(activation.ActivationError, "changed since"):
                self.apply()
            self.assertEqual(self.events, [])

    def test_change_during_metadata_query_is_rechecked_before_mutation(self):
        def concurrent(command, environment):
            status = self.run_command(command, environment)
            if command[0].endswith("/nix-store"):
                self.link(self.running, self.other)
            return status
        driver = self.driver()
        driver.runner = concurrent
        with self.assertRaisesRegex(activation.ActivationError, "changed since"):
            self.apply(driver)
        self.assertEqual(self.profile.resolve(), self.checkpoint)
        self.assertEqual(self.running.resolve(), self.other)
        self.assertEqual(len(self.events), 1)

    def test_change_after_profile_write_stops_candidate_activation(self):
        def concurrent(command, environment):
            status = self.run_command(command, environment)
            if command[0].endswith("/nix-env"):
                self.link(self.running, self.other)
            return status
        driver = self.driver()
        driver.runner = concurrent
        with self.assertRaisesRegex(activation.ActivationError, "recovery was incomplete"):
            self.apply(driver)
        self.assertEqual(self.running.resolve(), self.other)
        self.assertFalse(any(command[0] == str(self.candidate / "bin/switch-to-configuration") for command in self.events))

    def test_rejects_mutable_paths_derivations_aliases_and_traversal(self):
        alias = self.store / ("4" * 32 + "-alias")
        alias.symlink_to(self.candidate)
        for path in (str(self.root), str(alias), str(self.candidate) + "/../other",
                     str(self.candidate) + ".drv", str(self.store / "bad-name")):
            with self.subTest(path=path), self.assertRaises((activation.ActivationError, OSError)):
                self.driver().apply("switch", path, str(self.checkpoint), str(self.checkpoint))
        self.assertEqual(self.events, [])

    def test_activator_symlink_cannot_escape_store(self):
        program = self.candidate / "activate"
        program.unlink()
        program.symlink_to(sys.executable)
        with self.assertRaisesRegex(activation.ActivationError, "escapes"):
            self.apply(self.driver("Darwin"))
        self.assertEqual(self.events, [])

    def test_metadata_symlink_cannot_read_outside_store(self):
        metadata = self.candidate / "systemConfig"
        metadata.unlink()
        metadata.symlink_to(self.root / "unreadable-private-metadata")
        (self.root / "unreadable-private-metadata").write_text("SYNTHETIC_PRIVATE_INPUT")
        with self.assertRaisesRegex(activation.ActivationError, "escapes"):
            self.apply(self.driver("Darwin"))
        self.assertEqual(self.events, [])

    def test_broken_metadata_link_fails_before_mutation(self):
        metadata = self.candidate / "systemConfig"
        metadata.unlink()
        metadata.symlink_to(self.root / "missing")
        with self.assertRaises(OSError):
            self.apply(self.driver("Darwin"))
        self.assertEqual(self.events, [])

    def test_group_writable_activator_is_rejected(self):
        (self.candidate / "activate").chmod(0o775)
        with self.assertRaises(activation.ActivationError):
            self.apply(self.driver("Darwin"))
        self.assertEqual(self.events, [])

    def test_failed_store_validity_never_changes_profile(self):
        self.fail_validity = True
        with self.assertRaises(activation.ActivationError) as raised:
            self.apply()
        self.assertEqual(raised.exception.status, 7)
        self.assertEqual(self.profile.resolve(), self.checkpoint)
        self.assertEqual(len(self.events), 1)

    def test_real_multicall_aliases_preserve_dispatch_and_transaction_convergence(self):
        log = self.root / "multicall.log"
        multicall = self.other / "bin/nix"
        multicall.write_text(f"#!{sys.executable} -I\n" + f'''
import sys
from pathlib import Path
role = Path(sys.argv[0]).name
with Path({str(log)!r}).open("a") as output:
    output.write(role + "\\n")
if role == "nix-store" and sys.argv[1] == "--check-validity":
    raise SystemExit(0)
if role == "nix-env" and sys.argv[1:4:2] == ["--profile", "--set"]:
    profile = Path(sys.argv[2])
    profile.unlink()
    profile.symlink_to(sys.argv[4])
    raise SystemExit(0)
raise SystemExit(64)
''')
        multicall.chmod(0o555)
        (self.tools / "bin/nix").symlink_to(multicall)
        for name in ("nix-env", "nix-store"):
            alias = self.tools / "bin" / name
            alias.unlink()
            alias.symlink_to("nix")
        program = self.candidate / "bin/switch-to-configuration"
        program.unlink()
        program.write_text(f"#!{sys.executable} -I\n" + f'''
from pathlib import Path
running = Path({str(self.running)!r})
running.unlink()
running.symlink_to({str(self.candidate)!r})
''')
        program.chmod(0o555)
        self.apply(self.driver(runner=False))
        self.assertEqual(log.read_text().splitlines(), ["nix-store", "nix-env"])
        self.assertEqual(self.profile.resolve(), self.candidate)
        self.assertEqual(self.running.resolve(), self.candidate)

    def test_pinned_tools_reject_mutable_aliases_even_when_targets_are_in_store(self):
        outside = self.root / "nix-store"
        outside.symlink_to(self.other / "bin/nix-store")
        with self.assertRaisesRegex(activation.ActivationError, "canonical store"):
            self.driver().pinned_tool(str(outside), "nix-store")
        inside = self.tools / "bin/nix-store"
        inside.unlink()
        inside.symlink_to(outside)
        with self.assertRaisesRegex(activation.ActivationError, "escapes"):
            self.apply()
        self.assertEqual(self.events, [])

    def test_pinned_tool_alias_parent_and_role_remain_protected(self):
        tool = self.tools / "bin/nix-store"
        tool.unlink()
        tool.symlink_to(self.other / "bin/nix-store")
        (self.tools / "bin").chmod(0o775)
        with self.assertRaisesRegex(activation.ActivationError, "unprotected path"):
            self.apply()
        (self.tools / "bin").chmod(0o755)
        driver = self.driver()
        driver.nix_env = str(tool)
        with self.assertRaisesRegex(activation.ActivationError, "fixed bin alias"):
            self.apply(driver)
        self.assertEqual(self.events, [])

    def test_partial_profile_failure_restores_selection_without_running_scripts(self):
        self.fail_profile = True
        with self.assertRaisesRegex(activation.ActivationError, "checkpoint outputs restored") as raised:
            self.apply()
        self.assertEqual(raised.exception.status, 17)
        self.assertEqual(self.profile.resolve(), self.checkpoint)
        self.assertEqual(len(self.events), 3)
        self.assertTrue(all(command[0].endswith(("/nix-env", "/nix-store")) for command in self.events))

    def test_failed_switch_recovers_profile_running_and_boot_outputs(self):
        for system in ("Linux", "Darwin"):
            with self.subTest(system=system):
                self.setUp_state()
                self.fail_activation = True
                with self.assertRaisesRegex(activation.ActivationError, "checkpoint outputs restored") as raised:
                    self.apply(self.driver(system))
                self.assertEqual(raised.exception.status, 23)
                self.assertEqual(self.profile.resolve(), self.checkpoint)
                self.assertEqual(self.running.resolve(), self.checkpoint)
                if system == "Linux":
                    self.assertEqual([command[-1] for command in self.events[-2:]], ["test", "boot"])

    def test_failed_test_recovers_running_without_profile_mutations(self):
        self.fail_activation = True
        with self.assertRaises(activation.ActivationError):
            self.apply(action="test")
        self.assertEqual(self.profile.resolve(), self.checkpoint)
        self.assertEqual(self.running.resolve(), self.checkpoint)
        self.assertFalse(any(command[0].endswith("/nix-env") for command in self.events))

    def test_failed_boot_restores_selected_boot_without_runtime_switch(self):
        self.fail_activation = True
        with self.assertRaises(activation.ActivationError):
            self.apply(action="boot")
        self.assertEqual(self.profile.resolve(), self.checkpoint)
        self.assertEqual(self.running.resolve(), self.checkpoint)
        self.assertEqual(self.events[-1][-1], "boot")

    def test_failed_recovery_reports_manual_action_and_original_status(self):
        self.fail_activation = self.fail_recovery = True
        with self.assertRaisesRegex(activation.ActivationError, "recovery was incomplete") as raised:
            self.apply()
        self.assertEqual(raised.exception.status, 23)

    def test_concurrent_new_profile_is_not_overwritten_by_recovery(self):
        self.fail_activation = self.concurrent = True
        with self.assertRaisesRegex(activation.ActivationError, "recovery was incomplete"):
            self.apply()
        self.assertEqual(self.profile.resolve(), self.other)

    def test_nonmutating_action_does_not_restore_over_concurrent_candidate_selection(self):
        self.fail_activation = True
        def concurrent(command, environment):
            status = self.run_command(command, environment)
            if status == 23:
                self.link(self.profile, self.candidate)
            return status
        driver = self.driver()
        driver.runner = concurrent
        with self.assertRaisesRegex(activation.ActivationError, "recovery was incomplete"):
            self.apply(driver, "test")
        self.assertEqual(self.profile.resolve(), self.candidate)

    def test_distinct_selected_and_running_checkpoints_are_both_restored(self):
        self.link(self.running, self.other)
        self.fail_activation = True
        with self.assertRaisesRegex(activation.ActivationError, "checkpoint outputs restored"):
            self.driver().apply("switch", str(self.candidate), str(self.checkpoint), str(self.other))
        self.assertEqual(self.profile.resolve(), self.checkpoint)
        self.assertEqual(self.running.resolve(), self.other)

    def test_concurrent_running_change_is_not_overwritten_by_recovery(self):
        self.fail_activation = True
        def concurrent(command, environment):
            status = self.run_command(command, environment)
            if status == 23:
                self.link(self.running, self.other)
            return status
        driver = self.driver()
        driver.runner = concurrent
        with self.assertRaisesRegex(activation.ActivationError, "recovery was incomplete"):
            self.apply(driver)
        self.assertEqual(self.running.resolve(), self.other)

    def test_legacy_user_activation_is_refused_before_mutation(self):
        legacy = self.candidate / "activate-user"
        legacy.write_text("#!/bin/sh\nexit 0\n")
        legacy.chmod(0o555)
        with self.assertRaisesRegex(activation.ActivationError, "Legacy activate-user"):
            self.apply(self.driver("Darwin"))
        self.assertEqual(self.events, [])

    def test_unsupported_actions_and_unprotected_profile_directory_are_rejected(self):
        for system, action in (("Darwin", "boot"), ("Linux", "activate"), ("Unknown", "switch")):
            with self.subTest(system=system, action=action), self.assertRaises(activation.ActivationError):
                self.apply(self.driver(system), action)
        self.profile.parent.chmod(0o777)
        with self.assertRaisesRegex(activation.ActivationError, "profile directory"):
            self.apply()
        self.assertEqual(self.events, [])

    def test_failed_convergence_is_not_reported_as_success(self):
        self.no_convergence = True
        with self.assertRaisesRegex(activation.ActivationError, "checkpoint outputs restored"):
            self.apply()
        self.assertEqual(self.profile.resolve(), self.checkpoint)

    def test_global_lock_excludes_other_runtime_directories_and_releases_on_error(self):
        with self.driver().locked():
            with self.assertRaisesRegex(activation.ActivationError, "in progress"):
                self.apply()
        with self.driver().locked():
            pass
        self.assertEqual(self.events, [])

    def test_lock_symlink_or_unsafe_mode_is_rejected(self):
        lock = self.profile.parent / ".nixi-activation.lock"
        lock.symlink_to(self.root / "another-file")
        with self.assertRaises(OSError):
            self.apply()
        lock.unlink()
        lock.write_text("")
        lock.chmod(0o666)
        with self.assertRaisesRegex(activation.ActivationError, "lock is not protected"):
            self.apply()

    def test_real_user_child_is_waited_after_handled_termination(self):
        driver = self.driver(runner=False)
        timer = threading.Timer(0.2, driver.signal, (signal.SIGTERM, None))
        timer.start()
        try:
            with self.assertRaises(activation.ActivationError) as raised:
                driver.run([sys.executable, "-I", "-c", "import time; time.sleep(10)"])
            self.assertEqual(raised.exception.status, 143)
            self.assertIsNone(driver.child)
        finally:
            timer.join()


class Boundary(unittest.TestCase):
    def test_environment_excludes_build_credentials_and_validates_sudo_identity(self):
        root = pwd.getpwuid(0)
        with patch.dict(os.environ, {"NIX_CONFIG": "SYNTHETIC_TOKEN", "SSH_AUTH_SOCK": "/tmp/fixture",
                "DOTFILES": "/tmp/consumer", "PYTHONPATH": "/tmp/injection", "SUDO_USER": root.pw_name,
                "SUDO_UID": str(root.pw_uid), "SUDO_GID": str(root.pw_gid)}):
            env = activation.activation_environment()
            self.assertFalse({"NIX_CONFIG", "SSH_AUTH_SOCK", "DOTFILES", "PYTHONPATH"} & env.keys())
            self.assertEqual(env["SUDO_USER"], root.pw_name)
            self.assertEqual(env["NIX_USER_CONF_FILES"], "/dev/null")
            with patch.dict(os.environ, {"SUDO_UID": "invalid"}):
                self.assertNotIn("SUDO_USER", activation.activation_environment())

    def test_cli_refuses_nonroot_before_any_transaction(self):
        args = ["helper", "--action", "switch", "--candidate", "invalid",
                "--expected-profile", "invalid", "--expected-running", "invalid"]
        with patch.object(sys, "argv", args), patch.object(os, "geteuid", return_value=501), patch("sys.stderr", new_callable=io.StringIO):
            with self.assertRaises(SystemExit) as raised:
                activation.main("Darwin", "unused", "unused")
            self.assertEqual(raised.exception.code, 1)

    @unittest.skipUnless(os.environ.get("NIXI_SYSTEM_ACTIVATOR"), "packaged launcher check")
    def test_packaged_launcher_ignores_python_import_environment(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            marker = root / "injected"
            (root / "sitecustomize.py").write_text(f"from pathlib import Path\nPath({str(marker)!r}).touch()\n")
            env = os.environ | {"NIX_PYTHONPATH": directory, "PYTHONPATH": directory,
                                "PYTHONHOME": directory, "__PYVENV_LAUNCHER__": "/invalid"}
            result = subprocess.run([os.environ["NIXI_SYSTEM_ACTIVATOR"], "--help"],
                                    env=env, text=True, capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(marker.exists())


if __name__ == "__main__":
    unittest.main()
