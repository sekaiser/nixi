# A plain K3s server. Networking, CNI, GitOps, and secret providers are composed
# by the consumer or an opt-in profile, not implied by this service switch.
{
  config,
  lib,
  ...
}: let
  cfg = config.modules.services.k3s-server;
  native = config.services.k3s;
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
    assertions = [
      {
        assertion = !native.enable || native.role == "server";
        message = "modules.services.k3s-server requires the effective K3s role to be server; disable the adapter when selecting another role.";
      }
    ];
    services.k3s =
      {
        enable = lib.mkDefault true;
        role = lib.mkDefault "server";
        extraFlags = lib.mkIf native.enable (
          ["--write-kubeconfig-mode=0600" "--secrets-encryption"]
          ++ lib.optional (cfg.k8sServiceHost != "") "--tls-san=${cfg.k8sServiceHost}"
          ++ lib.optional (cfg.agentTokenFile != null) "--agent-token-file=${cfg.agentTokenFile}"
        );
      }
      // lib.optionalAttrs (cfg.tokenFile != null) {tokenFile = cfg.tokenFile;};
  };
}
