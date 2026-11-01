{
  config,
  lib,
  ...
}: let
  inherit (lib) mkIf;

  cfg = config.modules.shell.direnv;
in {
  config = mkIf cfg.enable {
    programs = {
      direnv = {
        enable = true;
        nix-direnv.enable = true;
        settings.global.hide_env_diff = cfg.hideEnvDiff;
      };
    };
  };
}
