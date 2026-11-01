{
  nixi,
  lib,
  runCommand,
  ...
}: let
  outputs = nixi.lib.mkHostFlake {
    inputs = {
      self.outPath = ./fixtures/cli-host;
      inherit nixi;
    };
    hosts.server = {
      system = "x86_64-linux";
      module = _: {
        config = {
          modules.profiles.user = "alice";
          home.stateVersion = "26.05";
          system.stateVersion = "26.05";
        };
      };
    };
  };
  host = outputs.nixosConfigurations.server;
  config = host.config;
  user = config.users.users.alice;
  admin = (host.extendModules {modules = [{modules.profiles.administrator.enable = true;}];}).config;
  workstation = (host.extendModules {modules = [{modules.profiles.workstation.enable = true;}];}).config;
  docker = (host.extendModules {modules = [{modules.services.docker.enable = true;}];}).config;
  dockerAccess =
    (host.extendModules {
      modules = [
        {
          modules.services.docker = {
            enable = true;
            grantRootAccess = true;
          };
        }
      ];
    }).config;
  dockerRootless =
    (host.extendModules {
      modules = [
        {
          modules.services.docker = {
            enable = true;
            rootless = true;
          };
        }
      ];
    }).config;
  runtimePassword = (host.extendModules {modules = [{modules.profiles.primary-user.hashedPasswordFile = "/run/secrets/login-hash";}];}).config;
  literalPassword = (host.extendModules {modules = [{modules.profiles.primary-user.initialHashedPassword = "synthetic";}];}).config;
  dockerPrune = enabled:
    (host.extendModules {
      modules = [
        {
          modules.services.docker.enable = true;
          virtualisation.docker.autoPrune = {
            enable = enabled;
            dates = "daily";
            flags = ["--filter=until=168h"];
          };
        }
      ];
    })
    .config;
  secure = host.extendModules {modules = [{modules.profiles.secure-ssh.enable = true;}];};
  ssh = host.extendModules {modules = [{modules.services.ssh.enable = true;}];};
  nativeSsh =
    (ssh.extendModules {
      modules = [
        {
          services.openssh = {
            ports = [2222];
            moduliFile = "/fixture/moduli";
            settings = {
              AllowUsers = ["alice"];
              PasswordAuthentication = false;
              UseDns = false;
              X11Forwarding = true;
              GSSAPIAuthentication = true;
              TrustedUserCAKeys = "/fixture/trusted-user-ca.pub";
            };
          };
        }
      ];
    })
    .config;
  disabledSsh =
    (ssh.extendModules {
      modules = [
        {
          services.openssh.enable = false;
          modules.services.ssh.hostCertificates.fixture.sourceFile = "/fixture/host-cert.pub";
        }
      ];
    })
    .config;
  secureOverride =
    (secure.extendModules {
      modules = [
        {
          modules.services.ssh.passwordAuthentication = true;
          services.openssh.settings.PermitRootLogin = "prohibit-password";
        }
      ];
    })
    .config;
in
  assert ssh.config.services.openssh.ports == [22];
  assert ssh.config.services.openssh.settings.AllowUsers == null;
  assert ssh.config.services.openssh.settings.PasswordAuthentication;
  assert !ssh.config.services.openssh.settings.UseDns;
  assert !ssh.config.services.openssh.settings.X11Forwarding;
  assert !ssh.config.services.openssh.settings.GSSAPIAuthentication;
  assert nativeSsh.services.openssh.ports == [2222];
  assert nativeSsh.networking.firewall.allowedTCPPorts == [2222];
  assert nativeSsh.services.openssh.settings.AllowUsers == ["alice"];
  assert !nativeSsh.services.openssh.settings.PasswordAuthentication;
  assert !nativeSsh.services.openssh.settings.UseDns;
  assert nativeSsh.services.openssh.settings.X11Forwarding;
  assert nativeSsh.services.openssh.settings.GSSAPIAuthentication;
  assert nativeSsh.services.openssh.moduliFile == "/fixture/moduli";
  assert nativeSsh.services.openssh.settings.TrustedUserCAKeys == "/fixture/trusted-user-ca.pub";
  assert !disabledSsh.services.openssh.enable;
  assert disabledSsh.networking.firewall.allowedTCPPorts == [];
  assert !(disabledSsh.systemd.services ? nixi-ssh-host-certificates);
  assert !(disabledSsh.systemd.timers ? nixi-ssh-host-certificates);
  assert user.extraGroups == [];
  assert !user.ignoreShellProgramCheck;
  assert user.shell == config.users.defaultUserShell;
  assert admin.users.users.alice.extraGroups == ["wheel"];
  assert workstation.users.users.alice.extraGroups == [];
  assert !workstation.users.users.alice.ignoreShellProgramCheck;
  assert workstation.users.users.alice.shell == host.pkgs.zsh;
  assert workstation.programs.zsh.enable;
  assert docker.users.users.alice.extraGroups == [];
  assert dockerAccess.users.users.alice.extraGroups == ["docker"];
  assert dockerRootless.virtualisation.docker.rootless.enable;
  assert !dockerRootless.virtualisation.docker.enable;
  assert dockerRootless.users.users.alice.extraGroups == [];
  assert runtimePassword.users.users.alice.hashedPasswordFile == "/run/secrets/login-hash";
  assert lib.any (a: !a.assertion && lib.hasInfix "Inline primary-user" a.message) literalPassword.assertions;
  assert !docker.virtualisation.docker.autoPrune.enable;
  assert !docker.virtualisation.docker.enableOnBoot;
  assert !(docker.systemd.timers ? docker-prune);
  assert docker.systemd.services.docker-prune.wantedBy == [];
  assert !(dockerPrune false).virtualisation.docker.autoPrune.enable;
  assert (dockerPrune true).virtualisation.docker.autoPrune.enable;
  assert (dockerPrune true).systemd.timers.docker-prune.timerConfig.OnCalendar == ["daily"];
  assert (dockerPrune true).virtualisation.docker.autoPrune.flags == ["--filter=until=168h"];
  assert docker.networking.firewall.allowedTCPPorts == config.networking.firewall.allowedTCPPorts;
  assert secure.config.services.openssh.enable;
  assert !secure.config.services.openssh.settings.PasswordAuthentication;
  assert !secure.config.services.openssh.settings.KbdInteractiveAuthentication;
  assert secure.config.services.openssh.settings.PermitRootLogin == "no";
  assert secureOverride.services.openssh.settings.PasswordAuthentication;
  assert secureOverride.services.openssh.settings.PermitRootLogin == "prohibit-password";
  assert builtins.deepSeq config.modules.theme.fonts true;
  assert !(config.modules.theme.fonts ? packages);
  assert lib.all (name: !(config.modules.theme.fonts.${name} ? package)) ["mono" "sans" "terminal" "icons"];
  assert lib.all (name: !(nixi.lib ? ${name}) && !(nixi.lib.pkgs ? ${name})) ["mkWrapper" "mkLauncherEntry" "toPrettyJSON" "compileSCSS"];
    runCommand "user-policy-check" {} ''touch "$out"''
