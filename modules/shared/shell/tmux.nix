# Neutral per-user tmux configuration. Workstation plugins and bindings are opt-in.
{
  hey,
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkIf;
  inherit (lib.types) either listOf path str;
  inherit (hey.lib) mkBoolOpt mkOpt;
  cfg = config.modules.shell.tmux;
  quote = value: "'" + lib.replaceStrings ["'"] ["'\\''"] (toString value) + "'";
in {
  options.modules.shell.tmux = {
    enable = mkBoolOpt false;
    autoAttach = mkBoolOpt false;
    sessionSelector = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ../../../packages/tmuxsel.nix {};
      description = "Interactive session selector used by macOS auto-attach. Installed independently of Hey; its mainProgram is invoked with no arguments.";
    };
    term = mkOpt str "xterm-256color";
    rcFiles = mkOpt (listOf (either str path)) [];
  };

  config = mkIf cfg.enable {
    user.packages = [pkgs.tmux];
    home.configFile."tmux/tmux.conf".source = lib.mkDefault (pkgs.writeText "nixi-tmux.conf" ''
      set -s default-terminal ${quote cfg.term}
      ${lib.concatMapStringsSep "\n" (file: "source-file ${quote file}") (hey.lib.uniqueContentPaths cfg.rcFiles)}
    '');
  };
}
