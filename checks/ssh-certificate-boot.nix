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
      name = "ssh-certificate-boot";
      requiredFeatures = lib.optionalAttrs allowSoftwareEmulation {
        kvm = false;
        apple-virt = false;
        nixos-test = false;
      };
      qemu.forceAccel = !allowSoftwareEmulation;
      globalTimeout = 420;
      node.specialArgs.hey = {
        lib = nixi.lib;
        frameworkDir = toString ../.;
      };
      defaults = {
        pkgs,
        lib,
        ...
      }: {
        imports = [../modules/platform/linux/services/ssh.nix];
        # This focused fixture imports only the Linux host-certificate module.
        options.modules.services.ssh.userCertificates = lib.mkOption {
          type = lib.types.attrs;
          default = {};
        };
        config = {
          users.users.fixture = {
            isNormalUser = true;
            createHome = true;
          };
          environment.systemPackages = [(pkgs.callPackage ../packages/ssh-certificate.nix {})];
          modules.services.ssh = {
            enable = true;
            hostCertificateDependencies = ["fixture-ca.service"];
            hostCertificates.fixture = {
              caKeyFile = "/run/fixture-ca/key";
              principals = ["localhost"];
            };
          };
          systemd.services.fixture-ca = {
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
            };
            script = ''
              sleep 2
              install -d -m 0700 /run/fixture-ca
              ${pkgs.openssh}/bin/ssh-keygen -q -t ed25519 -N "" -f /run/fixture-ca/key
            '';
          };
          virtualisation.memorySize = 384;
        };
      };
      nodes = {
        daemon = {};
        socket.services.openssh.startWhenNeeded = true;
        blocked = {lib, ...}: {
          services.openssh.startWhenNeeded = true;
          systemd.services.fixture-ca.script = lib.mkForce "exit 1";
        };
      };
      testScript = ''
        start_all()
        for machine, unit in [(daemon, "sshd.service"), (socket, "sshd.socket")]:
            machine.wait_for_unit(unit, timeout=120)
            machine.succeed("test -s /etc/ssh/ssh_host_ed25519_key-cert.pub")
            machine.wait_until_succeeds("ssh-keyscan -c -t ed25519 localhost 2>/dev/null | grep ssh-ed25519-cert", timeout=30)
            old = machine.succeed("cat /etc/ssh/ssh_host_ed25519_key-cert.pub")
            machine.sleep(1)
            machine.succeed("systemctl start nixi-ssh-host-certificates.service")
            assert old != machine.succeed("cat /etc/ssh/ssh_host_ed25519_key-cert.pub")
            # Certificate scans omit the hostname: both files use field 2.
            machine.wait_until_succeeds("ssh-keyscan -c -t ed25519 localhost 2>/dev/null | cut -d ' ' -f 2 | grep -Fx \"$(cut -d ' ' -f 2 /etc/ssh/ssh_host_ed25519_key-cert.pub)\"", timeout=30)
            renewed = machine.succeed("cat /etc/ssh/ssh_host_ed25519_key-cert.pub")
            machine.succeed("mv /run/fixture-ca/key /run/fixture-ca/key.saved")
            machine.fail("systemctl start nixi-ssh-host-certificates.service")
            assert renewed == machine.succeed("cat /etc/ssh/ssh_host_ed25519_key-cert.pub")
        blocked.wait_until_succeeds("systemctl is-failed fixture-ca.service", timeout=120)
        blocked.fail("systemctl is-active sshd.socket")
        blocked.fail("test -e /etc/ssh/ssh_host_ed25519_key-cert.pub")
        # Root-assisted user signing must not borrow root's read access.
        daemon.succeed("mv /run/fixture-ca/key.saved /run/fixture-ca/key")
        daemon.succeed("runuser -u fixture -- ssh-keygen -q -t ed25519 -N \"\" -f /home/fixture/key")
        sign_user = "nixi-ssh-certificate user --ca-key /run/fixture-ca/key --public-key /home/fixture/key.pub --certificate /home/fixture/cert.pub --user fixture --group users --principals '[\"fixture\"]' --required"
        daemon.succeed(sign_user)
        old_user = daemon.succeed("cat /home/fixture/cert.pub")
        daemon.succeed("mv /home/fixture/key.pub /root/private-key.pub; chmod 600 /root/private-key.pub; ln -s /root/private-key.pub /home/fixture/key.pub")
        daemon.fail(sign_user)
        assert old_user == daemon.succeed("cat /home/fixture/cert.pub")
        daemon.succeed("unlink /home/fixture/key.pub; mkfifo /home/fixture/key.pub; chown fixture:users /home/fixture/key.pub")
        status, _ = daemon.execute("timeout 8 " + sign_user)
        assert status not in (0, 124), "FIFO must be rejected, not left for the timeout to kill"
        assert old_user == daemon.succeed("cat /home/fixture/cert.pub")
      '';
    };
}
