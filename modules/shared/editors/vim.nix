# The legacy vim selector installs Neovim without workstation preferences.
{
  hey,
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkIf;
  inherit (hey.lib) mkBoolOpt;

  cfg = config.modules.editors.vim;
in {
  options.modules.editors.vim = {
    enable = mkBoolOpt false;
  };

  config = mkIf cfg.enable {
    user.packages = [
      pkgs.unstable.neovim
    ];
  };
}
