{
  nixi,
  lib,
  runCommand,
  ...
}: let
  base =
    (nixi.lib.mkHostFlake {
      inputs = {
        self.outPath = ./fixtures/cli-host;
        inherit nixi;
      };
      hosts.fixture = {
        system = "x86_64-linux";
        module = _: {
          config = {
            user = {
              name = "fixture";
              home = "/home/fixture";
            };
            home.stateVersion = "26.05";
            system.stateVersion = "26.05";
          };
        };
      };
    })
    .nixosConfigurations
    .fixture;
  configure = module: (base.extendModules {modules = [module];}).config;
  enabled = name: {
    modules.services.${
      if name == "openssh"
      then "ssh"
      else name
    }.enable =
      true;
  };
  disabled = name:
    configure {
      imports = [(enabled name)];
      services.${name}.enable = false;
      # Even explicitly configured authentication must not leave helper units.
      modules.services.tailscale.keyFile = lib.mkIf (name == "tailscale") "/run/fixture-key";
    };
  caddy = configure {
    imports = [(enabled "caddy")];
    services.caddy = {
      openFirewall = true;
      httpPort = 8080;
      httpsPort = 8443;
    };
  };
  tang = configure {
    imports = [(enabled "tang")];
    services.tang = {
      listenStream = ["9000"];
      ipAddressAllow = ["192.0.2.0/24"];
    };
  };
  tailscale = configure {
    imports = [(enabled "tailscale")];
    modules.services.tailscale.extraUpFlags = ["--hostname=legacy"];
    services.tailscale.port = 41642;
    services.tailscale.extraUpFlags = ["--hostname=native"];
  };
  ssh = configure {
    imports = [(enabled "openssh")];
    services.openssh.ports = [2222];
  };
  closed = name:
    configure {
      imports = [(enabled name)];
      services.${name} =
        lib.optionalAttrs (name != "tang") {openFirewall = false;}
        // lib.optionalAttrs (name == "tang") {
          listenStream = ["127.0.0.1:9000"];
          ipAddressAllow = ["localhost"];
        };
      modules.services.tang.openFirewall = lib.mkIf (name == "tang") false;
    };
  noOpenings = config:
    config.networking.firewall.allowedTCPPorts
    == base.config.networking.firewall.allowedTCPPorts
    && config.networking.firewall.allowedUDPPorts == base.config.networking.firewall.allowedUDPPorts;
  allServices = ["caddy" "tang" "tailscale" "openssh"];
  dockerDisabled = configure {
    modules.services.docker = {
      enable = true;
      grantRootAccess = true;
    };
    virtualisation.docker.enable = false;
  };
  rootlessDisabled = configure {
    modules.services.docker = {
      enable = true;
      rootless = true;
    };
    virtualisation.docker.rootless.enable = false;
  };
  bothDockerDaemonsDisabled = configure {
    modules.services.docker = {
      enable = true;
      rootless = true;
      grantRootAccess = true;
    };
    user.extraGroups = ["wheel"];
    virtualisation.docker = {
      enable = false;
      rootless.enable = false;
    };
  };
  k3sDisabled = role:
    configure {
      modules.services."k3s-${role}".enable = true;
      services.k3s.enable = false;
    };
  ciliumDisabled = configure {
    modules.services.k3s-server.enable = true;
    modules.profiles.k3s-cilium = {
      enable = true;
      apiHost = "k3s.example.invalid";
      flux.enable = true;
    };
    services.k3s.enable = false;
  };
  orphanCilium = configure {modules.profiles.k3s-cilium.enable = true;};
  wrongRole = role:
    configure {
      modules.services."k3s-${role}".enable = true;
      services.k3s.role =
        if role == "server"
        then "agent"
        else "server";
    };
in
  assert lib.all (name: !(disabled name).services.${name}.enable && noOpenings (disabled name)) allServices;
  assert lib.all (name: noOpenings (closed name)) allServices;
  assert !((disabled "caddy").systemd.services ? caddy);
  assert !((disabled "tang").systemd.sockets ? tangd);
  assert !((disabled "tailscale").systemd.services ? tailscale-fetch-ip);
  assert !((disabled "tailscale").systemd.services ? tailscaled-autoconnect);
  assert !((disabled "tailscale").systemd.services ? tailscaled);
  assert caddy.networking.firewall.allowedTCPPorts == [8080 8443];
  assert caddy.networking.firewall.allowedUDPPorts == [8443];
  assert tang.systemd.sockets.tangd.socketConfig.ListenStream == ["9000"];
  assert tang.networking.firewall.allowedTCPPorts == [9000];
  assert tailscale.networking.firewall.allowedUDPPorts == [41642];
  assert tailscale.services.tailscale.extraUpFlags == ["--hostname=native"];
  assert ssh.networking.firewall.allowedTCPPorts == [2222];
  assert !dockerDisabled.virtualisation.docker.enable;
  assert !dockerDisabled.virtualisation.docker.rootless.enable;
  assert dockerDisabled.users.users.fixture.extraGroups == base.config.users.users.fixture.extraGroups;
  assert !(dockerDisabled.systemd.services ? docker);
  assert !(dockerDisabled.systemd.sockets ? docker);
  assert !(dockerDisabled.systemd.services ? docker-prune);
  # The adapter still deliberately supplies a client for remote Docker use.
  assert builtins.elem base.pkgs.docker dockerDisabled.user.packages;
  assert dockerDisabled.hey.capabilities == base.config.hey.capabilities;
  assert dockerDisabled.hey.info.enabled == base.config.hey.info.enabled;
  assert !rootlessDisabled.virtualisation.docker.enable;
  assert !rootlessDisabled.virtualisation.docker.rootless.enable;
  assert !rootlessDisabled.virtualisation.docker.rootless.setSocketVariable;
  assert !(rootlessDisabled.systemd.user.services ? docker);
  assert bothDockerDaemonsDisabled.users.users.fixture.extraGroups == ["wheel"];
  assert !lib.any (a: !a.assertion && lib.hasInfix "Choose rootless Docker" a.message) bothDockerDaemonsDisabled.assertions;
  assert lib.all (role: let
    cfg = k3sDisabled role;
  in
    !cfg.services.k3s.enable
    && !(cfg.systemd.services ? k3s)
    && cfg.services.k3s.extraFlags == []
    && cfg.users.users.fixture.packages == base.config.users.users.fixture.packages
    && cfg.hey.capabilities == base.config.hey.capabilities
    && noOpenings cfg
    && !lib.any (a: !a.assertion && lib.hasPrefix "modules.services.k3s-" a.message) cfg.assertions) ["server" "agent"];
  assert lib.all (role: lib.any (a: !a.assertion && lib.hasInfix "effective K3s role" a.message) (wrongRole role).assertions) ["server" "agent"];
  assert ciliumDisabled.services.k3s.autoDeployCharts == {};
  assert ciliumDisabled.services.k3s.manifests == {};
  assert !(ciliumDisabled.systemd.services ? k3s);
  assert ciliumDisabled.networking.firewall.trustedInterfaces == base.config.networking.firewall.trustedInterfaces;
  assert !builtins.elem base.pkgs.cilium-cli ciliumDisabled.environment.systemPackages;
  assert lib.any (a: !a.assertion && a.message == "k3s-cilium requires modules.services.k3s-server.enable.") orphanCilium.assertions;
    runCommand "service-overrides-check" {} ''touch "$out"''
