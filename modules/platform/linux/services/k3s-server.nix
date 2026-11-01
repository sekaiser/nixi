# A plain K3s server. Networking, CNI, GitOps, and secret providers are composed
# by the consumer or an opt-in profile, not implied by this service switch.
{
  config,
  lib,
  ...
}: let
  cfg = config.modules.services.k3s-server;
  contracts = import ../../../../lib/internal/file-contracts.nix {inherit lib;};
in {
  options.modules.services.k3s-server = {
    enable = lib.mkEnableOption "K3s server";
    tokenFile = lib.mkOption {
      type = lib.types.nullOr contracts.runtimeSecretPath;
      default = null;
      description = "Runtime file containing the server token.";
    };
    agentTokenFile = lib.mkOption {
      type = lib.types.nullOr contracts.runtimeSecretPath;
      default = null;
      description = "Runtime file containing the agent token.";
    };
    k8sServiceHost = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Optional additional API hostname for TLS SANs.";
    };
  };
  config = lib.mkIf cfg.enable {
    services.k3s =
      {
        enable = true;
        role = "server";
        extraFlags =
          ["--write-kubeconfig-mode=0600" "--secrets-encryption"]
          ++ lib.optional (cfg.k8sServiceHost != "") "--tls-san=${cfg.k8sServiceHost}"
          ++ lib.optional (cfg.agentTokenFile != null) "--agent-token-file=${cfg.agentTokenFile}";
      }
      // lib.optionalAttrs (cfg.tokenFile != null) {tokenFile = cfg.tokenFile;};
  };
}
