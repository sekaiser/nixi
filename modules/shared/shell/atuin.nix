{
  config,
  hey,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkIf;
  inherit (hey.lib) mkBoolOpt;

  cfg = config.modules.shell.atuin;
  toml = pkgs.formats.toml {};
in {
  options.modules.shell.atuin = {
    enable = mkBoolOpt false;
    disableUpArrow = mkBoolOpt false;
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.unstable.atuin;
      description = "Atuin package used for shell history and its optional features.";
    };
    settings = lib.mkOption {
      type = toml.type;
      default = {};
      description = "Atuin settings; history sync and update checks default to disabled.";
    };
  };

  config = mkIf cfg.enable {
    user.packages = [cfg.package];

    modules.shell.atuin.settings = {
      auto_sync = lib.mkDefault false;
      update_check = lib.mkDefault false;
    };
    home.configFile."atuin/config.toml".source = toml.generate "atuin-config.toml" cfg.settings;

    modules.shell.zsh.rcInit = mkIf config.modules.shell.zsh.enable ''
      if (( $+commands[atuin] )); then
        eval "$(atuin init zsh${
        if cfg.disableUpArrow
        then " --disable-up-arrow"
        else ""
      })"
      fi
    '';
  };
}
