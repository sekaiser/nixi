{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.modules.shell.alacritty;
  shell = config.users.users.${config.user.name}.shell;
  shellPath =
    if lib.isDerivation shell
    then "${shell}${shell.shellPath}"
    else toString shell;
in {
  options.modules.shell.alacritty = {
    enable = lib.mkEnableOption "Alacritty with Nix terminfo and the configured login shell";
    extraConfig = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Trusted additional TOML; do not redefine env or terminal.shell. Stored publicly in the Nix store.";
    };
  };
  config = lib.mkIf cfg.enable {
    user.packages = [pkgs.alacritty];
    # nix-darwin discovers application bundles through system packages.
    environment.systemPackages = lib.optionals pkgs.stdenv.isDarwin [pkgs.alacritty];
    home.configFile."alacritty/alacritty.toml".text =
      ''
        [env]
        TERM = "alacritty"
        TERMINFO = "${lib.getOutput "terminfo" pkgs.alacritty}/share/terminfo"
      ''
      + lib.optionalString (pkgs.stdenv.isDarwin && shell != null) ''
        [terminal.shell]
        program = ${builtins.toJSON shellPath}
        args = ["-l"]
      ''
      + "\n"
      + cfg.extraConfig;
  };
}
