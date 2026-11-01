{
  lib,
  config,
  pkgs,
  ...
}: let
  inherit (lib) mkIf mkOption;
  inherit (lib.types) nullOr str;

  cfg = config.modules.profiles;
  primary = cfg.primary-user;
in {
  options.modules.profiles.primary-user = {
    description = mkOption {
      type = nullOr str;
      default = null;
      description = "Description for the selected primary user account.";
    };
  };

  config = mkIf (cfg.user != "") {
    user.name = cfg.user;
    user.description =
      if primary.description != null
      then primary.description
      else cfg.user;
    user.home = "/Users/${cfg.user}";
    user.shell = pkgs.zsh;
  };
}
