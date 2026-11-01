{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkIf;

  cfg = config.modules.shell.direnv;
in {
  config = mkIf cfg.enable {
    user.packages = [pkgs.direnv];
    home.configFile."direnv/direnv.toml" = {
      text = ''
        [global]
        hide_env_diff = ${if cfg.hideEnvDiff then "true" else "false"}
      '';
    };
    modules.shell.zsh.rcInit = ''eval "$(direnv hook zsh)"'';
  };
}
