{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkIf;

  cfg = config.modules.profiles.zsh-workstation;
in {
  config = mkIf (cfg.enable && config.modules.shell.zsh.enable) {
    programs.zsh = {
      # Respect XDG please.
      histFile = "$XDG_STATE_HOME/zsh/history";
      # Implement these manually and with caching.
      enableLsColors = false;
    };

    users.defaultUserShell = pkgs.zsh;

    user.packages = with pkgs.unstable; [
      at
      libqalculate
      unar
    ];

    # Ensure that ZSH's cache directory exists, lest we have IO errors early on.
    systemd.user.tmpfiles.rules = [
      "d %h/.cache/zsh 750 - - - -"
      "d %h/.local/state/zsh 700 - - - -"
    ];
  };
}
