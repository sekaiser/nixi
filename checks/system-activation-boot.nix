{
  systems = ["aarch64-linux" "x86_64-linux"];
  package = {
    lib,
    testers,
    callPackage,
    runCommand,
    coreutils,
    allowSoftwareEmulation ? false,
    ...
  }: let
    activation = callPackage ../packages/system-activation.nix {};
    # This protected store output is only a stale-checkpoint input. Its
    # activator must never run; positive cases use the real booted NixOS closure.
    stale = runCommand "nixi-stale-activation-checkpoint" {} ''
      mkdir -p "$out/bin"
      ln -s ${coreutils}/bin/false "$out/bin/switch-to-configuration"
    '';
  in
    testers.runNixOSTest {
      name = "system-activation-boot";
      requiredFeatures = lib.optionalAttrs allowSoftwareEmulation {
        kvm = false;
        apple-virt = false;
        nixos-test = false;
      };
      qemu.forceAccel = !allowSoftwareEmulation;
      globalTimeout = 300;
      nodes.machine = {
        pkgs,
        lib,
        ...
      }: {
        users.users.operator.isNormalUser = true;
        nix.enable = true;
        # NixOS's test base omits switching by default as a Hydra optimization.
        # This fixture needs the genuine NixOS activator, not a replacement.
        system.switch.enable = true;
        environment.systemPackages = [activation pkgs.nix];
        system.extraDependencies = [stale];
        # This VM boots its kernel directly. Keep bootloader installation out
        # of the switch/recovery contract rather than writing a guest boot menu.
        boot.loader.grub.enable = lib.mkForce false;
        environment.etc."nixi-activation-phase".text = "base\n";
        specialisation.changed.configuration = {
          environment.etc."nixi-activation-phase".text = lib.mkForce "changed\n";
          # Fail inside a genuine alternate NixOS activation after /etc changed.
          # The ERR handler retains failure while activation updates the running
          # checkpoint; EXIT records that state before Nixi attempts recovery.
          system.activationScripts.nixiSyntheticFailure = {
            deps = ["etc"];
            text = ''
              if [ -e /run/nixi-trigger-activation-failure ]; then
                cat /etc/nixi-activation-phase > /run/nixi-failed-phase
                readlink -f /nix/var/nix/profiles/system > /run/nixi-failed-profile
                trap 'readlink -f /run/current-system > /run/nixi-failed-running' EXIT
                false
              fi
            '';
          };
        };
        # Writes stay in this disposable guest's overlay/database/profile tree.
        # No host store/profile or existing VM is activated or modified.
        virtualisation.writableStore = true;
        virtualisation.memorySize = 768;
        virtualisation.cores = 2;
      };
      testScript = ''
        import shlex

        machine.start()
        machine.wait_for_unit("multi-user.target")
        machine.wait_for_unit("nix-daemon.socket")
        helper = "${activation}/bin/nixi-system-activate"
        stale = "${stale}"
        profile = "/nix/var/nix/profiles/system"
        profile_parent = "/nix/var/nix/profiles"
        lock = profile_parent + "/.nixi-activation.lock"
        current = machine.succeed("readlink -f /run/current-system").strip()
        machine.succeed("test -x " + shlex.quote(current + "/bin/switch-to-configuration"))
        machine.succeed("nix-store --check-validity " + shlex.quote(current))
        # Boot fixtures need not initially have a selected profile. Select only
        # the already-realized current closure; this never evaluates/builds it.
        machine.succeed("install -d -m 755 " + profile_parent)
        machine.succeed("nix-env --profile " + profile + " --set " + shlex.quote(current))
        changed = machine.succeed("readlink -f " + shlex.quote(current + "/specialisation/changed")).strip()
        assert changed != current
        machine.succeed("nix-store --check-validity " + shlex.quote(changed))
        assert machine.succeed("cat /etc/nixi-activation-phase") == "base\n"

        def generations():
            return set(machine.succeed("find " + profile_parent + " -maxdepth 1 -name 'system-*-link' -printf '%f\\n'").splitlines())

        initial_generations = generations()

        def command(action="dry-activate", candidate=None, expected_profile=None, expected_running=None):
            args = [helper, "--action", action, "--candidate", candidate or current,
                    "--expected-profile", expected_profile or current,
                    "--expected-running", expected_running or current]
            return shlex.join(args)

        def checkpoints():
            return machine.succeed("readlink -f " + profile + "; readlink -f /run/current-system")

        initial = checkpoints()

        def unchanged():
            assert checkpoints() == initial
            machine.fail("test -e /run/nixi-activation-poison-executed")

        def refused(cmd, message=None, expected_status=1):
            status, output = machine.execute(cmd + " 2>&1")
            assert status == expected_status, output
            if message:
                assert message in output, output
            unchanged()

        with subtest("root dry activation uses the realized booted closure and fixed checkpoints"):
            machine.succeed(command())
            unchanged()
            machine.succeed("test $(stat -c '%u:%a:%h' " + lock + ") = 0:600:1")

        with subtest("recipient cannot invoke privileged activation"):
            refused("runuser -u operator -- " + command(), "System activation requires root")

        with subtest("caller Python and Nix configuration cannot alter fixed-tool activation"):
            machine.succeed("install -d -m 700 /run/nixi-activation-poison")
            source = "from pathlib import Path\nPath('/run/nixi-activation-poison-executed').touch()\n"
            machine.succeed("printf %s " + shlex.quote(source) + " > /run/nixi-activation-poison/sitecustomize.py")
            machine.succeed("printf 'nixi_fixture_invalid_line\\n' > /run/nixi-activation-poison/nix.conf")
            poisoned = ("env PYTHONPATH=/run/nixi-activation-poison PYTHONHOME=/run/nixi-activation-poison "
                        "NIX_PYTHONPATH=/run/nixi-activation-poison "
                        "NIX_CONFIG=nixi_fixture_invalid_line "
                        "NIX_USER_CONF_FILES=/run/nixi-activation-poison/nix.conf "
                        "NIX_REMOTE=nixi-fixture-invalid://unavailable ")
            machine.succeed(poisoned + command())
            unchanged()

        with subtest("real NixOS test activation is idempotent and converges"):
            machine.succeed(command(action="test"))
            machine.wait_for_unit("multi-user.target")
            unchanged()
            machine.succeed(command(action="test"))
            unchanged()

        with subtest("stale selected and running checkpoints are refused before activation"):
            message = "System changed since build planning"
            refused(command(expected_profile=stale), message)
            refused(command(expected_running=stale), message)

        with subtest("privileged interface accepts only fixed realized-output inputs"):
            for candidate in ["/run/current-system", current + "/..", "flake:fixture", current + ".drv"]:
                refused(command(candidate=candidate))
            refused(command(action="build"), "Unsupported local system activation action")
            refused(command() + " --profile /run/nixi-profile-override", "unrecognized arguments", 2)
            machine.fail("test -e /run/nixi-profile-override")

        with subtest("real profile directory and lock permissions remain mandatory"):
            directory_mode = machine.succeed("stat -c %a " + profile_parent).strip()
            try:
                machine.succeed("chmod g+w " + profile_parent)
                refused(command(), "System profile directory is not protected")
            finally:
                machine.succeed("chmod " + directory_mode + " " + profile_parent)
            try:
                machine.succeed("chmod 644 " + lock)
                refused(command(), "System activation lock is not protected")
            finally:
                machine.succeed("chmod 600 " + lock)
            machine.succeed(command())
            unchanged()

        with subtest("distinct realized system switch and explicit return converge without pruning generations"):
            machine.succeed(command(action="switch", candidate=changed))
            machine.wait_for_unit("multi-user.target")
            assert checkpoints().splitlines() == [changed, changed]
            assert machine.succeed("cat /etc/nixi-activation-phase") == "changed\n"
            machine.succeed(command(action="switch", expected_profile=changed, expected_running=changed))
            machine.wait_for_unit("multi-user.target")
            unchanged()
            assert machine.succeed("cat /etc/nixi-activation-phase") == "base\n"
            assert initial_generations <= generations()
            machine.succeed("nix-store --check-validity " + shlex.quote(current) + " " + shlex.quote(changed))

        with subtest("failed distinct-system activation restores both real checkpoints and configuration"):
            before_failure = generations()
            machine.succeed("touch /run/nixi-trigger-activation-failure")
            refused(command(action="switch", candidate=changed), "checkpoint outputs restored", 2)
            # These observations were taken by the failing real activator before
            # recovery: all three states actually reached the candidate.
            assert machine.succeed("cat /run/nixi-failed-phase") == "changed\n"
            assert machine.succeed("cat /run/nixi-failed-profile").strip() == changed
            assert machine.succeed("cat /run/nixi-failed-running").strip() == changed
            assert machine.succeed("cat /etc/nixi-activation-phase") == "base\n"
            assert before_failure <= generations()
            machine.succeed("nix-store --check-validity " + shlex.quote(current) + " " + shlex.quote(changed))
            machine.succeed("rm /run/nixi-trigger-activation-failure")
            machine.succeed(command())
            unchanged()

        machine.shutdown()
      '';
    };
}
