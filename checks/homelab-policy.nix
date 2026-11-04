{
  nixi,
  lib,
  runCommand,
  ...
}: let
  # Synthetic provider: no real SOPS input, encrypted file or secret is read.
  provider = {lib, ...}: {
    options.sops = {
      defaultSopsFile = lib.mkOption {type = lib.types.str;};
      age.keyFile = lib.mkOption {type = lib.types.nullOr lib.types.str;};
      age.sshKeyPaths = lib.mkOption {type = lib.types.listOf lib.types.str;};
      gnupg.sshKeyPaths = lib.mkOption {type = lib.types.listOf lib.types.str;};
      secrets = lib.mkOption {
        default = {};
        type = lib.types.attrsOf (lib.types.submodule ({name, ...}: {
          options = {
            sopsFile = lib.mkOption {type = lib.types.str;};
            path = lib.mkOption {
              type = lib.types.str;
              default = "/run/fixture-secrets/${name}";
            };
          };
        }));
      };
    };
  };
  outputs = nixi.lib.mkHostFlake {
    inputs = {
      self.outPath = ./fixtures/cli-host;
      inherit nixi;
      sops-nix.nixosModules.sops = provider;
    };
    hosts = lib.genAttrs ["server" "agent"] (role: {
      system = "x86_64-linux";
      module = _: {
        config = {
          user = {
            name = "alice";
            home = "/home/alice";
          };
          home.stateVersion = "26.05";
          system.stateVersion = "26.05";
          modules.profiles = {
            homelab-base.user = "alice";
            homelab-secrets.defaultSopsFile = "/fixture/secrets.yaml";
            "homelab-k3s-${role}" =
              {
                enable = true;
              }
              // (
                if role == "server"
                then {k8sServiceHost = "k3s.example.invalid";}
                else {serverHost = "k3s.example.invalid";}
              );
          };
        };
      };
    });
  };
  custom = role: (outputs.nixosConfigurations.${role}.extendModules {
    modules = [
      {
        modules.profiles."homelab-k3s-${role}" =
          {
            agentTokenSecret = "cluster/join-token";
            tailscaleAuthSecret = "network/join-key";
          }
          // lib.optionalAttrs (role == "server") {
            podCIDR = "192.0.2.0/24";
            serviceCIDR = "198.51.100.0/24";
          };
      }
    ];
  });
  server = (custom "server").config;
  agent = (custom "agent").config;
  noRoutes =
    ((custom "server").extendModules {
      modules = [{modules.profiles.homelab-k3s-server.advertisedRoutes = [];}];
    })
    .config;
  defaults = outputs.nixosConfigurations.server.config;
  disabled = role:
    ((custom role).extendModules {modules = [{services.k3s.enable = false;}];}).config;
  # NixOS applies autoDeployCharts into a generated HelmChart manifest.
  serverManifest = builtins.fromJSON server.services.k3s.autoDeployCharts.cilium.source.value;
  serverValues = builtins.fromJSON (builtins.head serverManifest.items).spec.valuesContent;
in
  assert defaults.modules.profiles.homelab-k3s-server.advertisedRoutes == ["10.42.0.0/16" "10.43.0.0/16"];
  assert lib.all (cfg: builtins.attrNames cfg.sops.secrets == ["cluster/join-token" "network/join-key"]) [server agent];
  assert server.modules.services.k3s-server.agentTokenFile == "/run/fixture-secrets/cluster/join-token";
  assert agent.modules.services.k3s-agent.tokenFile == "/run/fixture-secrets/cluster/join-token";
  assert server.modules.services.tailscale.keyFile == "/run/fixture-secrets/network/join-key";
  assert agent.modules.services.tailscale.keyFile == "/run/fixture-secrets/network/join-key";
  assert server.modules.profiles.k3s-cilium.podCIDRs == ["192.0.2.0/24"];
  assert serverValues.ipam.operator.clusterPoolIPv4PodCIDRList == ["192.0.2.0/24"];
  assert builtins.elem "--cluster-cidr=192.0.2.0/24" server.services.k3s.extraFlags;
  assert builtins.elem "--service-cidr=198.51.100.0/24" server.services.k3s.extraFlags;
  assert builtins.elem "--advertise-routes=192.0.2.0/24,198.51.100.0/24" server.services.tailscale.extraUpFlags;
  assert builtins.elem "--advertise-routes=" noRoutes.services.tailscale.extraUpFlags;
  assert lib.all (role: !((disabled role).systemd.services ? k3s)) ["server" "agent"];
  assert lib.all (role: lib.all (interface: !builtins.elem interface (disabled role).networking.firewall.trustedInterfaces) ["cilium_host" "cilium_net" "lxc+"]) ["server" "agent"];
  assert lib.all (role: builtins.elem "tailscale0" (disabled role).networking.firewall.trustedInterfaces) ["server" "agent"];
    runCommand "homelab-policy-check" {} ''touch "$out"''
