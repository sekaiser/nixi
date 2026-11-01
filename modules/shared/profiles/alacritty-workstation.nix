{
  hey,
  pkgs,
  config,
  lib,
  ...
}: let
  inherit (builtins) readFile replaceStrings;
  inherit (lib) mkIf mkMerge;
  inherit (hey.lib) mkBoolOpt;

  cfg = config.modules.profiles.alacritty-workstation;
  colors = config.modules.theme.colors;
  urlOpenCommand =
    if pkgs.stdenv.hostPlatform.isDarwin
    then "open"
    else "xdg-open";
  themeColors = ''
    [colors.primary]
    background = '${colors.types.bg}'
    foreground = '${colors.types.fg}'

    [colors.cursor]
    text = '${colors.types.bg}'
    cursor = '${colors.types.highlight}'

    [colors.selection]
    text = 'CellForeground'
    background = '${colors.types.selection}'

    [colors.normal]
    black = '${colors.black}'
    red = '${colors.red}'
    green = '${colors.green}'
    yellow = '${colors.yellow}'
    blue = '${colors.blue}'
    magenta = '${colors.magenta}'
    cyan = '${colors.cyan}'
    white = '${colors.silver}'

    [colors.bright]
    black = '${colors.grey}'
    red = '${colors.brightred}'
    green = '${colors.brightgreen}'
    yellow = '${colors.brightyellow}'
    blue = '${colors.brightblue}'
    magenta = '${colors.brightmagenta}'
    cyan = '${colors.brightcyan}'
    white = '${colors.white}'
  '';
in {
  options.modules.profiles.alacritty-workstation = {
    enable = mkBoolOpt false;
  };

  config = mkIf cfg.enable (mkMerge [
    {
      modules.shell.alacritty.enable = lib.mkDefault true;
      modules.shell.alacritty.extraConfig = lib.mkDefault (
        replaceStrings
        ["@URL_OPEN_COMMAND@"]
        [urlOpenCommand]
        (readFile "${hey.assetsDir}/alacritty/alacritty.toml")
        + "\n"
        + themeColors
      );
    }

    (mkIf (pkgs.stdenv.hostPlatform.isDarwin && config.modules.shell.alacritty.enable) {
      system.activationScripts.postActivation.text = ''
        /usr/bin/sudo -H -u ${config.user.name} /usr/bin/defaults write org.alacritty NSWindowTabbingEnabled -bool false
      '';
    })
  ]);
}
