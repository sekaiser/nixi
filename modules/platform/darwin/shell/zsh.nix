{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkIf;

  cfg = config.modules.shell.zsh;
in {
  config = mkIf cfg.enable {
    # Match the system/login shell and tmux's helper dependency. Mixing in
    # unstable Zsh can collide at bin/zsh when the user profile is assembled.
    user.packages = [pkgs.zsh];
  };
}
