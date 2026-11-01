{
  config,
  lib,
  ...
}: let
  inherit (lib) mkEnableOption mkIf mkOption;
  inherit (lib.types) nonEmptyStr nullOr port str;

  cfg = config.modules.profiles.homelab-k3s-agent;
  effectiveServerAddr =
    if cfg.serverAddr != null
    then cfg.serverAddr
    else "https://${cfg.serverHost}:${toString cfg.serverPort}";
in {
  options.modules.profiles.homelab-k3s-agent = {
    enable = mkEnableOption "shared homelab k3s agent defaults";
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

    serverHost = mkOption {
      type = nullOr str;
      default = null;
      description = "Default k3s server hostname for homelab agent nodes.";
    };

    serverPort = mkOption {
      type = port;
      default = 6443;
      description = "Default k3s server API port for homelab agent nodes.";
    };

    serverAddr = mkOption {
      type = nullOr str;
      default = null;
      description = "Full k3s server address for homelab agent nodes. Overrides serverHost/serverPort when set.";
    };
  };

  config = mkIf cfg.enable {
    services.k3s = {
      environmentFile = "/var/tailscale/ip";
      extraFlags = ["--kubelet-arg=register-with-taints=node.cilium.io/agent-not-ready:NoExecute"];
    };
    systemd.services.k3s = {
      after = ["tailscale-fetch-ip.service"];
      requires = ["tailscale-fetch-ip.service"];
    };
    networking.firewall = {
      checkReversePath = "loose";
      trustedInterfaces = ["tailscale0" "cilium_host" "cilium_net" "lxc+"];
    };
    assertions = [
      {
        assertion = cfg.serverAddr != null || cfg.serverHost != null;
        message = "modules.profiles.homelab-k3s-agent requires either serverAddr or serverHost.";
      }
    ];

    modules = {
      profiles = {
        homelab-node.enable = true;
        homelab-secrets = {
          enable = true;
          secretNames = [
            cfg.agentTokenSecret
            cfg.tailscaleAuthSecret
          ];
        };
      };

      services = {
        k3s-agent = {
          enable = true;
          serverAddr = effectiveServerAddr;
          tokenFile = config.sops.secrets.${cfg.agentTokenSecret}.path;
        };

        tailscale = {
          enable = true;
          keyFile = config.sops.secrets.${cfg.tailscaleAuthSecret}.path;
          useRoutingFeatures = "both";
          extraUpFlags = [
            "--accept-routes"
            "--accept-dns"
          ];
        };
      };
    };
  };
}
