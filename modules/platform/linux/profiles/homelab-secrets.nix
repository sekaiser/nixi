{
  hey,
  config,
  lib,
  ...
}: let
  inherit (lib) genAttrs mkDefault mkEnableOption mkIf mkMerge mkOption optional optionalAttrs;
  inherit (lib.types) bool listOf nullOr str;

  cfg = config.modules.profiles.homelab-secrets;
  contracts = import ../../../../lib/internal/file-contracts.nix {inherit lib;};
  hasSopsNix = hey.inputs ? sops-nix && hey.inputs.sops-nix ? nixosModules;
in {
  imports = optional hasSopsNix hey.inputs.sops-nix.nixosModules.sops;

  options.modules.profiles.homelab-secrets = {
    enable = mkEnableOption "shared homelab SOPS defaults";

    defaultSopsFile = mkOption {
      type = nullOr str;
      default = null;
      description = "Default SOPS file used by homelab hosts.";
    };

    ageKeyFile = mkOption {
      type = contracts.runtimeSecretPath;
      default = "/var/lib/sops-nix/key.txt";
      description = "Age identity path used by homelab hosts.";
    };

    useHostSshKey = mkOption {
      type = bool;
      default = false;
      description = "Whether to derive the SOPS age identity from host SSH keys instead of ageKeyFile.";
    };

    sshKeyPaths = mkOption {
      type = listOf contracts.runtimeSecretPath;
      default = ["/etc/ssh/ssh_host_ed25519_key"];
      description = "SSH host private keys used as SOPS age identities when useHostSshKey is enabled.";
    };

    secretNames = mkOption {
      type = listOf str;
      default = [];
      description = "SOPS secret names to expose from defaultSopsFile.";
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      assertions = [
        {
          assertion = cfg.defaultSopsFile != null;
          message = "modules.profiles.homelab-secrets.defaultSopsFile must be set.";
        }
        {
          assertion = hasSopsNix;
          message = "modules.profiles.homelab-secrets requires hey.inputs.sops-nix when enabled.";
        }
      ];
    }

    (optionalAttrs hasSopsNix {
      sops.defaultSopsFile = cfg.defaultSopsFile;

      # Select one identity source; sops-nix otherwise imports OpenSSH keys
      # by default. Native sops settings remain available as explicit overrides.
      sops.age = {
        sshKeyPaths = mkDefault (
          if cfg.useHostSshKey
          then cfg.sshKeyPaths
          else []
        );
        keyFile = mkDefault (
          if cfg.useHostSshKey
          then null
          else cfg.ageKeyFile
        );
      };
      sops.gnupg.sshKeyPaths = mkDefault [];

      sops.secrets = genAttrs cfg.secretNames (_: {
        sopsFile = cfg.defaultSopsFile;
      });
    })
  ]);
}
