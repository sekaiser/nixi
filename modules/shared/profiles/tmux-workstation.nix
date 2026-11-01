{
  hey,
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkIf;

  cfg = config.modules.shell.tmux;
in {
  options.modules.profiles.tmux-workstation.enable = lib.mkEnableOption "the opinionated tmux workstation preset";
  config = mkIf config.modules.profiles.tmux-workstation.enable (lib.mkMerge [
    {modules.shell.tmux.enable = lib.mkDefault true;}
    (mkIf config.modules.shell.tmux.enable {
      user.packages = [
        pkgs.tmux
        pkgs.zsh # Bundled bindings invoke zsh even when the login shell is different.
        cfg.sessionSelector
        (pkgs.callPackage ../../../packages/tmux-status.nix {})
      ];

      modules.shell.zsh = mkIf config.modules.shell.zsh.enable {
        rcInit = ''
          if (( $+commands[tmuxifier] )); then
            eval "$(tmuxifier init -)"
          fi
        '';
        rcFiles = ["${hey.assetsDir}/tmux/aliases.zsh"];
      };

      home.configFile = {
        "tmux/tmux.conf".source = "${hey.assetsDir}/tmux/tmux.conf";
        "tmux/aliases.zsh".source = "${hey.assetsDir}/tmux/aliases.zsh";
        "tmux/bin" = {
          source = "${hey.assetsDir}/tmux/bin";
          recursive = true;
        };
      };

      home-manager.users.${config.user.name}.home = {
        sessionVariables = {
          HEY_TMUX_SELECTOR = lib.getExe cfg.sessionSelector;
          HEY_TMUX_AUTO_ATTACH =
            if cfg.autoAttach
            then "1"
            else "0";
          TMUX_HOME = "${config.home.configDir}/tmux";
          TMUXIFIER = "${config.home.dataDir}/tmuxifier";
          TMUXIFIER_LAYOUT_PATH = "${config.home.dataDir}/tmuxifier";
        };
        sessionPath = ["${config.home.dataDir}/tmuxifier/bin"];
      };
    })
  ]);
}
