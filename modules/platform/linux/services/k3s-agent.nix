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
  native = config.services.k3s;
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
      default = "";
      description = "Address of the k3s server.";
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      assertions = [
        {
          assertion = !native.enable || cfg.tokenFile != null;
          message = "modules.services.k3s-agent.tokenFile must be set when enabled.";
        }
        {
          assertion = !native.enable || cfg.serverAddr != "";
          message = "modules.services.k3s-agent.serverAddr must not be empty.";
        }
        {
          assertion = !native.enable || native.role == "agent";
          message = "modules.services.k3s-agent requires the effective K3s role to be agent; disable the adapter when selecting another role.";
        }
      ];

      user.packages = lib.optionals native.enable [
        pkgs.git
      ];

      services.k3s.enable = lib.mkDefault true;
      services.k3s.role = lib.mkDefault "agent";
      services.k3s.serverAddr = cfg.serverAddr;
      services.k3s.tokenFile = cfg.tokenFile;
    }
  ]);
}
