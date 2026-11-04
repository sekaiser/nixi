{
  systems = ["aarch64-linux" "x86_64-linux"];
  package = {
    lib,
    nixi,
    testers,
    allowSoftwareEmulation ? false,
    ...
  }:
    testers.runNixOSTest {
      name = "openvpn-client-boot";
      # The default check retains hardware/test-runner scheduling requirements.
      # Explicit isolated reproductions may use the test framework's documented
      # TCG fallback without changing the machine or builder configuration.
      requiredFeatures = lib.optionalAttrs allowSoftwareEmulation {
        kvm = false;
        apple-virt = false;
        nixos-test = false;
      };
      qemu.forceAccel = !allowSoftwareEmulation;
      globalTimeout = 300;
      nodes.machine = {
        lib,
        pkgs,
        ...
      }: let
        yamlPython = pkgs.python3.withPackages (ps: [ps.pyyaml]);
        ompActivationFixture = (pkgs.callPackage ./agent-integration.nix {inherit nixi;}).ompActivationFixture;
      in {
        imports = [../modules/platform/linux/profiles/eks-bastion.nix];
        # This fixture imports the production OpenVPN adapter, while keeping
        # unrelated AWS package-selection modules outside its boot graph.
        options = {
          user.name = lib.mkOption {
            type = lib.types.str;
            default = "operator";
          };
          modules.shell.awscli2 = lib.mkOption {
            type = lib.types.attrs;
            default = {};
          };
        };
        config = {
          users.users.operator.isNormalUser = true;
          users.users.attacker.isNormalUser = true;
          modules.profiles.eks-bastion = {
            enable = true;
            openvpn = {
              enable = true;
              name = "fixture";
              autoStart = false;
              allowUserServiceControl = true;
              configFile = "/run/fixture-provider/current/client.conf";
              authFile = "/run/fixture-provider/current/auth";
            };
          };
          # Exercise real systemd root preStart/RuntimeDirectory/sudo semantics.
          # The daemon is a data-only observer: this is not VPN negotiation,
          # routing or server-certificate acceptance, and makes no VPN connection.
          systemd.services.openvpn-fixture.serviceConfig = {
            Type = lib.mkForce "simple";
            Restart = lib.mkForce "no";
            ExecStart = lib.mkForce (pkgs.writeShellScript "observe-openvpn-snapshot" ''
              set -eu
              test "$(id -u)" = 0
              test "$(stat -c '%u:%g:%a' /run/openvpn-fixture)" = 0:0:700
              for file in client.conf auth-user-pass input-0 input-1; do
                test "$(stat -c '%u:%g:%a' /run/openvpn-fixture/$file)" = 0:0:400
                test ! -L /run/openvpn-fixture/$file
              done
              ! grep -F '/run/fixture-provider' /run/openvpn-fixture/client.conf
              printf 'started\n' >> /run/fixture-daemon-starts
              exec ${pkgs.coreutils}/bin/sleep infinity
            '');
          };
          environment.systemPackages = [
            yamlPython
            (pkgs.callPackage ../packages/install-user-file.nix {})
            (pkgs.writeShellScriptBin "fixture-omp-sync" ''
              exec ${yamlPython}/bin/python3 -I ${../tools/sync_omp_config.py} "$@"
            '')
            (pkgs.writeShellScriptBin "fixture-omp-activation" ''
              set -e
              export OMP_FIXTURE_CONFIG="$1"
              source ${nixi.inputs.home-manager}/lib/bash/home-manager.sh
              source ${ompActivationFixture}
            '')
          ];
          virtualisation.memorySize = 512;
          virtualisation.cores = 2;
        };
      };
      testScript = ''
        import json
        import shlex

        machine.start()
        machine.wait_for_unit("multi-user.target")
        unit = "openvpn-fixture.service"
        systemctl = "/run/current-system/sw/bin/systemctl"

        def as_user(user, command):
            return "runuser -u " + user + " -- sh -c " + shlex.quote(command)

        def granted(action):
            return as_user("operator", "sudo -n " + systemctl + " " + action + " " + unit)

        def rejected_restart():
            before = machine.succeed("wc -l < /run/fixture-daemon-starts")
            machine.fail(granted("restart"))
            machine.wait_until_succeeds("systemctl is-failed " + unit)
            assert machine.succeed("wc -l < /run/fixture-daemon-starts") == before
            machine.fail("test -e /run/fixture-payload-ran")
            machine.fail("journalctl -u " + unit + " --no-pager | grep -E 'fixture-password-(one|two)'")
            machine.succeed(granted("reset-failed"))

        with subtest("root-owned provider generations and private immutable snapshots"):
            machine.succeed("install -d -m 700 /run/fixture-provider /run/fixture-provider/generation-1 /run/fixture-provider/generation-2")
            for generation, password in [("generation-1", "one"), ("generation-2", "two")]:
                root = "/run/fixture-provider/" + generation
                config = "client\nremote vpn.example.invalid 1194\nca /run/fixture-provider/current/ca.pem\nkey /run/fixture-provider/current/key.pem\n"
                machine.succeed("printf %s " + shlex.quote(config) + " > " + root + "/client.conf")
                machine.succeed("printf 'fixture-user\\nfixture-password-" + password + "\\n' > " + root + "/auth")
                machine.succeed("printf 'synthetic certificate\\n' > " + root + "/ca.pem; printf 'synthetic key\\n' > " + root + "/key.pem; chmod 600 " + root + "/*")
            machine.succeed("ln -s generation-1 /run/fixture-provider/current")
            machine.succeed(granted("start"))
            machine.wait_for_unit(unit)
            machine.wait_until_succeeds("test -s /run/fixture-daemon-starts")
            before = machine.succeed("sha256sum /run/openvpn-fixture/*")
            machine.succeed("ln -sfn generation-2 /run/fixture-provider/current")
            assert machine.succeed("sha256sum /run/openvpn-fixture/*") == before
            machine.fail(as_user("attacker", "cat /run/openvpn-fixture/auth-user-pass"))
            machine.fail(as_user("operator", "printf changed > /run/openvpn-fixture/client.conf"))
            machine.fail(as_user("attacker", "ln -sfn /home/attacker /run/fixture-provider/current"))
            machine.succeed(granted("restart"))
            machine.wait_for_unit(unit)
            machine.wait_until_succeeds("test $(wc -l < /run/fixture-daemon-starts) = 2")
            machine.succeed("grep -Fx fixture-password-two /run/openvpn-fixture/auth-user-pass")

        with subtest("service control is exact and recipient-scoped"):
            machine.fail(as_user("attacker", "sudo -n " + systemctl + " restart " + unit))
            machine.fail(granted("stop"))
            machine.fail(as_user("operator", "sudo -n " + systemctl + " start sshd.service"))
            machine.fail(as_user("operator", "sudo -n " + systemctl + " start " + unit + " sshd.service"))
            machine.succeed("systemctl is-active " + unit)

        with subtest("unsafe hooks cannot run through an authorized restart"):
            machine.succeed("printf '#!/bin/sh\\ntouch /run/fixture-payload-ran\\n' > /run/fixture-provider/payload; chmod 700 /run/fixture-provider/payload")
            machine.succeed("cp /run/fixture-provider/generation-2/client.conf /run/fixture-provider/client.saved")
            machine.succeed("printf 'up /run/fixture-provider/payload\\n' >> /run/fixture-provider/generation-2/client.conf")
            rejected_restart()
            machine.succeed("cp /run/fixture-provider/client.saved /run/fixture-provider/generation-2/client.conf")

        with subtest("real input ownership and ancestor permissions fail closed"):
            machine.succeed("chmod 644 /run/fixture-provider/generation-2/auth")
            rejected_restart()
            machine.succeed("chmod 600 /run/fixture-provider/generation-2/auth; chown attacker:users /run/fixture-provider/generation-2/auth")
            rejected_restart()
            machine.succeed("chown root:root /run/fixture-provider/generation-2/auth; chmod g+w /run/fixture-provider/generation-2")
            rejected_restart()
            machine.succeed("chmod 700 /run/fixture-provider/generation-2")

        with subtest("provider links cannot cross a user-controlled ancestor"):
            machine.succeed("install -d -o attacker -g users -m 700 /home/attacker/provider; cp /run/fixture-provider/generation-2/* /home/attacker/provider/; chown -R attacker:users /home/attacker/provider")
            machine.succeed("ln -sfn /home/attacker/provider /run/fixture-provider/current")
            rejected_restart()
            machine.succeed("ln -sfn generation-2 /run/fixture-provider/current")

        with subtest("special files are rejected promptly and clean input recovers"):
            machine.succeed("mv /run/fixture-provider/generation-2/auth /run/fixture-provider/auth.saved; mkfifo -m 600 /run/fixture-provider/generation-2/auth")
            status, _ = machine.execute("timeout 10 " + granted("restart"))
            assert status not in (0, 124), "FIFO must fail before the outer timeout"
            machine.wait_until_succeeds("systemctl is-failed " + unit)
            machine.succeed("rm /run/fixture-provider/generation-2/auth; mv /run/fixture-provider/auth.saved /run/fixture-provider/generation-2/auth")
            machine.succeed(granted("reset-failed"))
            machine.succeed(granted("start"))
            machine.wait_for_unit(unit)
            machine.succeed("test $(wc -l < /run/fixture-daemon-starts) = 3")
            machine.succeed("grep -Fx fixture-password-two /run/openvpn-fixture/auth-user-pass")

        with subtest("root-assisted tracked installation and recipient-only exact retirement"):
            installer = "/run/current-system/sw/bin/nixi-install-user-file"
            source = "/run/fixture-provider/installation-source"
            target = "/home/operator/.config/nixi-fixture/installed"
            receipt = "/home/operator/.local/state/nixi-fixture/receipt.json"
            machine.succeed("printf 'synthetic-installed-value\\n' > " + source + "; chmod 600 " + source)
            install = installer + " --receipt " + receipt + " " + source + " " + target + " operator users 0600"
            machine.fail(as_user("operator", "cat " + source))
            machine.succeed(install)
            machine.succeed("test $(stat -c '%u:%g:%a' " + target + ") = $(id -u operator):$(id -g operator):600")
            machine.succeed("test $(stat -c '%u:%g:%a' " + receipt + ") = $(id -u operator):$(id -g operator):600")
            machine.fail("grep -E 'synthetic-installed-value|fixture-provider' " + receipt)
            preview = installer + " --preview-retirement " + receipt
            machine.fail(preview)
            machine.fail(as_user("attacker", preview))
            first = json.loads(machine.succeed(as_user("operator", preview)))
            assert first["status"] == "ready" and first["destination"] == target
            machine.succeed(as_user("operator", "printf 'recipient-change\\n' >> " + target))
            status, output = machine.execute(as_user("operator", preview))
            assert status == 1
            changed = json.loads(output)
            assert changed["status"] == "changed" and "reviewToken" not in changed
            retire = installer + " --retire-receipt " + receipt + " --review-token "
            machine.fail(as_user("operator", retire + first["reviewToken"]))
            machine.succeed("grep -Fx recipient-change " + target)
            machine.succeed(install)
            second = json.loads(machine.succeed(as_user("operator", preview)))
            assert second["status"] == "ready" and second["reviewToken"] != first["reviewToken"]
            neighbor = "/home/operator/.config/nixi-fixture/untracked"
            machine.succeed(as_user("operator", "printf preserve > " + neighbor))
            retired = json.loads(machine.succeed(as_user("operator", retire + second["reviewToken"])))
            assert retired["status"] == "retired"
            machine.fail("test -e " + target)
            machine.succeed("test -f " + receipt + "; test $(cat " + neighbor + ") = preserve; grep -Fx synthetic-installed-value " + source)
            missing = json.loads(machine.succeed(as_user("operator", preview)))
            assert missing["status"] == "missing"

        with subtest("OMP helper honors real recipient and foreign-owner boundaries"):
            defaults = "/run/fixture-omp-defaults.yml"
            config = "/home/operator/.config/nixi-omp/config.yml"
            omp = "/run/current-system/sw/bin/fixture-omp-sync --defaults " + defaults + " --config " + config
            first_defaults = "theme:\n  dark: titanium\nmodelRoles:\n  slow: fixture/model\n"
            machine.succeed("printf %s " + shlex.quote(first_defaults) + " > " + defaults + "; chmod 644 " + defaults)
            machine.fail(omp)
            machine.fail("test -e /home/operator/.config/nixi-omp")
            machine.succeed(as_user("operator", "mkdir -m 700 /home/operator/.config/nixi-omp"))
            initial = "theme:\n  light: user-choice\nstartup:\n  quiet: true\nprivateExample: SYNTHETIC_OMP_USER_VALUE\n"
            machine.succeed(as_user("operator", "umask 077; printf %s " + shlex.quote(initial) + " > " + config))
            machine.succeed(as_user("operator", omp))
            for suffix in ["", ".nixi-managed.json", ".nixi-lock"]:
                machine.succeed("test $(stat -c '%u:%g:%a' " + config + suffix + ") = $(id -u operator):$(id -g operator):600")
            inspect = "import json,yaml; print(json.dumps(yaml.safe_load(open(" + repr(config) + "))))"
            data = json.loads(machine.succeed("python3 -c " + shlex.quote(inspect)))
            assert data["theme"] == {"dark": "titanium", "light": "user-choice"}
            assert data["startup"]["quiet"] and data["privateExample"] == "SYNTHETIC_OMP_USER_VALUE"
            before = machine.succeed("sha256sum " + config)
            machine.fail(as_user("attacker", omp))
            machine.succeed(as_user("operator", omp))
            assert machine.succeed("sha256sum " + config) == before
            edit = "from pathlib import Path; import yaml; p=Path(" + repr(config) + "); d=yaml.safe_load(p.read_text()); d['modelRoles']['slow']='recipient-change'; p.write_text(yaml.safe_dump(d, sort_keys=False))"
            machine.succeed(as_user("operator", "python3 -c " + shlex.quote(edit)))
            machine.succeed("printf 'symbolPreset: unicode\\n' > " + defaults)
            machine.succeed(as_user("operator", omp))
            data = json.loads(machine.succeed("python3 -c " + shlex.quote(inspect)))
            assert data["symbolPreset"] == "unicode" and "dark" not in data["theme"]
            assert data["theme"]["light"] == "user-choice" and data["modelRoles"]["slow"] == "recipient-change"
            before = machine.succeed("sha256sum " + config)
            machine.succeed("chown attacker:users /home/operator/.config/nixi-omp")
            status, output = machine.execute(as_user("operator", omp))
            assert status == 1 and "SYNTHETIC_OMP_USER_VALUE" not in output
            assert machine.succeed("sha256sum " + config) == before
            machine.succeed("chown operator:users /home/operator/.config/nixi-omp")
            machine.succeed(as_user("operator", omp))

        with subtest("generated OMP activation runs only for the recipient"):
            config = "/home/operator/.config/nixi-omp-activation/config.yml"
            activation = "/run/current-system/sw/bin/fixture-omp-activation " + config
            machine.succeed(as_user("operator", "DRY_RUN=1 " + activation))
            machine.fail("test -e /home/operator/.config/nixi-omp-activation")
            machine.fail(activation)
            machine.succeed(as_user("operator", "mkdir -m 700 /home/operator/.config/nixi-omp-activation; umask 077; printf 'privateExample: SYNTHETIC_ACTIVATION_VALUE\\nstartup:\\n  quiet: true\\n' > " + config))
            machine.succeed(as_user("operator", activation))
            inspect = "import json,yaml; print(json.dumps(yaml.safe_load(open(" + repr(config) + "))))"
            data = json.loads(machine.succeed("python3 -c " + shlex.quote(inspect)))
            assert data["theme"] == {"dark": "titanium", "light": "light"}
            assert data["privateExample"] == "SYNTHETIC_ACTIVATION_VALUE" and data["startup"]["quiet"]
            machine.succeed("test $(stat -c '%u:%g:%a' " + config + ") = $(id -u operator):$(id -g operator):600")
            before = machine.succeed("sha256sum " + config)
            machine.fail(as_user("attacker", activation))
            machine.succeed(as_user("operator", activation))
            assert machine.succeed("sha256sum " + config) == before
      '';
    };
}
