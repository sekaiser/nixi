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
    runCommand "service-overrides-check" {} ''touch "$out"''
