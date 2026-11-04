{
  config,
  lib,
  ...
}: let
  inherit (lib) mkEnableOption mkIf mkOption unique;
  inherit (lib.types) listOf nonEmptyStr str;

  cfg = config.modules.profiles.homelab-k3s-server;
in {
  options.modules.profiles.homelab-k3s-server = {
    enable = mkEnableOption "shared homelab k3s server defaults";

    k8sServiceHost = mkOption {
      type = str;
      default = "";
      description = "Hostname advertised by the k3s server.";
    };

    secretNames = mkOption {
      type = listOf str;
      default = [];
      description = "Additional SOPS secret names to expose on this server.";
    };
    agentTokenSecret = mkOption {
      type = nonEmptyStr;
      default = "k3s/agent_token";
      description = "Consumer-owned SOPS name for the shared K3s agent token.";
    };
    tailscaleAuthSecret = mkOption {
      type = nonEmptyStr;
      default = "tailscale/homelab_auth_key";
      description = "Consumer-owned SOPS name for the Tailscale authentication key.";
    };
    podCIDR = mkOption {
      type = nonEmptyStr;
      default = "10.42.0.0/16";
      description = "Pod CIDR shared by K3s, Cilium IPAM and default advertised routes.";
    };
    serviceCIDR = mkOption {
      type = nonEmptyStr;
      default = "10.43.0.0/16";
      description = "K3s service CIDR and default advertised service route.";
    };
    advertisedRoutes = mkOption {
      type = listOf nonEmptyStr;
      default = [cfg.podCIDR cfg.serviceCIDR];
      description = "Tailscale subnet routes. An empty list clears route advertisement.";
    };
  };

  config = mkIf cfg.enable {
    modules = {
      profiles = {
        k3s-cilium = {
          enable = true;
          apiHost = cfg.k8sServiceHost;
          podCIDRs = lib.mkDefault [cfg.podCIDR];
          flux.enable = true;
        };
        homelab-node.enable = true;
        homelab-secrets = {
          enable = true;
          secretNames = unique ([
              cfg.agentTokenSecret
              cfg.tailscaleAuthSecret
            ]
            ++ cfg.secretNames);
        };
      };

      services.k3s-server = {
        enable = true;
        k8sServiceHost = cfg.k8sServiceHost;
        agentTokenFile = config.sops.secrets.${cfg.agentTokenSecret}.path;
      };

      services.tailscale.keyFile = config.sops.secrets.${cfg.tailscaleAuthSecret}.path;
      services.tailscale = {
        enable = true;
        useRoutingFeatures = "both";
        extraUpFlags = [
          "--accept-routes"
          "--accept-dns"
          "--advertise-routes=${lib.concatStringsSep "," cfg.advertisedRoutes}"
        ];
      };
    };
    services.k3s = {
      environmentFile = "/var/tailscale/ip";
      extraFlags = [
        "--service-cidr=${cfg.serviceCIDR}"
        "--bind-address \${TAILSCALE_IP}"
        "--advertise-address \${TAILSCALE_IP}"
        "--tls-san \${TAILSCALE_IP}"
        "--node-ip \${TAILSCALE_IP}"
        "--node-external-ip \${TAILSCALE_IP}"
      ];
    };
    systemd.services.k3s = mkIf config.services.k3s.enable {
      after = ["tailscale-fetch-ip.service"];
      requires = ["tailscale-fetch-ip.service"];
    };
    networking.firewall.trustedInterfaces = ["tailscale0"];
  };
}
