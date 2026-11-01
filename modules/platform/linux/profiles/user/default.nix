{
  lib,
  config,
  ...
}: let
  inherit (lib) mkIf mkOption;
  inherit (lib.types) bool int listOf nullOr package str;

  cfg = config.modules.profiles;
  primary = cfg.primary-user;
  contracts = import ../../../../../lib/internal/file-contracts.nix {inherit lib;};
in {
  options.modules.profiles.primary-user = {
    description = mkOption {
      type = str;
      default = "The primary user account";
      description = "Description for the selected primary user account.";
    };

    uid = mkOption {
      type = int;
      default = 1000;
      description = "UID for the selected primary user account.";
    };

    group = mkOption {
      type = str;
      default = "users";
      description = "Primary group for the selected primary user account.";
    };

    extraGroups = mkOption {
      type = listOf str;
      default = [];
      description = "Supplementary groups for the selected primary user account.";
    };

    initialHashedPassword = mkOption {
      type = nullOr str;
      default = null;
      description = "Removed insecure interface. Use hashedPasswordFile; non-null literals are rejected.";
    };

    hashedPasswordFile = mkOption {
      type = nullOr contracts.runtimeSecretPath;
      default = null;
      description = "Runtime file containing the password hash. Never a Nix store file or literal hash.";
    };

    ignoreShellProgramCheck = mkOption {
      type = bool;
      default = false;
      description = "Whether to skip shell membership checks for the selected primary user account.";
    };

    shell = mkOption {
      type = nullOr package;
      default = null;
      description = "Optional login shell override; null keeps the native NixOS default.";
    };
  };

  config = mkIf (cfg.user != "") {
    assertions = [
      {
        assertion = primary.initialHashedPassword == null;
        message = "Inline primary-user password hashes are no longer supported. Provision a runtime secret and set primary-user.hashedPasswordFile; no automatic authentication migration is performed.";
      }
    ];
    user.name = cfg.user;
    user.isNormalUser = true;
    user.home = "/home/${cfg.user}";
    user.description = primary.description;
    user.group = primary.group;
    user.uid = primary.uid;
    user.extraGroups = primary.extraGroups;
    user.shell = mkIf (primary.shell != null) primary.shell;
    user.ignoreShellProgramCheck = primary.ignoreShellProgramCheck;
    user.hashedPasswordFile = mkIf (primary.hashedPasswordFile != null) primary.hashedPasswordFile;
  };
}
