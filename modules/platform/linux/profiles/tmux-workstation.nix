{
  config,
  hey,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) concatMapStrings mkIf;
  inherit (pkgs.unstable.tmuxPlugins) yank;

  cfg = config.modules.shell.tmux;
  uniqueRcFiles = hey.lib.uniqueContentPaths cfg.rcFiles;
in {
  config = mkIf (cfg.enable && config.modules.profiles.tmux-workstation.enable) {
    # I avoid programs.tmux because it comes with extra magic I don't need.
    environment.etc."tmux.conf".text = ''
      set -s default-terminal "${cfg.term}"

      source-file "$TMUX_HOME/tmux.conf"
      ${concatMapStrings (path: "source-file '${path}'\n") uniqueRcFiles}

      # Run plugins
      run-shell ${yank.rtp}
    '';
  };
}
