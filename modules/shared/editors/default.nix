{
  hey,
  config,
  lib,
  ...
}: let
  inherit (lib) mkDefault mkIf;
  inherit (lib.types) nullOr str;
  inherit (hey.lib) mkOpt';

  cfg = config.modules.editors;
in {
  imports = [
    ./emacs.nix
    ./vim.nix
    ./zed.nix
  ];

  options.modules.editors = {
    default = mkOpt' (nullOr str) null "Optional EDITOR command for the primary user. Null preserves native settings; selecting a command does not install its package.";
  };

  config = mkIf (cfg.default != null) {
    home-manager.users.${config.user.name}.home.sessionVariables.EDITOR = mkDefault cfg.default;
  };
}
