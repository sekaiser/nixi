{
  hey,
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (builtins) toString;
  inherit (lib) mkIf mkMerge mkOption types;
  inherit (hey.lib) mkBoolOpt';

  cfg = config.modules.services.k3s-agent;
  contracts = import ../../../../lib/internal/file-contracts.nix {inherit lib;};
in {
  options.modules.services.k3s-agent = {
    enable = mkBoolOpt' false "Whether to enable this host as a k3s agent.";

    tokenFile = mkOption {
      type = types.nullOr contracts.runtimeSecretPath;
      default = null;
      description = "Path to a runtime file containing the k3s agent token.";
    };

    serverAddr = mkOption {
      type = types.str;
      description = "Address of the k3s server.";
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      assertions = [
        {
          assertion = cfg.tokenFile != null;
          message = "modules.services.k3s-agent.tokenFile must be set when enabled.";
        }
        {
          assertion = cfg.serverAddr != "";
          message = "modules.services.k3s-agent.serverAddr must not be empty.";
        }
      ];

      user.packages = [
        pkgs.git
      ];

      services.k3s.enable = true;
      services.k3s.role = "agent";
      services.k3s.serverAddr = cfg.serverAddr;
      services.k3s.tokenFile = cfg.tokenFile;
    }
  ]);
}
