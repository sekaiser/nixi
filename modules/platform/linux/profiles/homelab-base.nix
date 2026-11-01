{
  config,
  lib,
  ...
}: let
  inherit (lib) mkEnableOption mkIf mkOption;
  inherit (lib.types) nullOr str;

  cfg = config.modules.profiles.homelab-base;
in {
  options.modules.profiles.homelab-base = {
    enable = mkEnableOption "shared homelab user defaults";

    user = mkOption {
      type = nullOr str;
      default = null;
      description = "Primary user profile enabled by this homelab base profile.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.user != null;
        message = "modules.profiles.homelab-base.user must be set.";
      }
    ];

    modules = {
      profiles.user = cfg.user;
      editors = {
        default = "nvim";
        vim.enable = true;
      };
      shell = {
        git.enable = true;
        zsh.enable = true;
      };
      services.ssh.enable = true;
      theme.active = "alucard";
    };

    environment.localBinInPath = true;
  };
}
