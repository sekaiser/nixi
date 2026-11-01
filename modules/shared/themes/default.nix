# Theme modules are a special beast. They're the only modules that are deeply
# intertwined with others, and are solely responsible for aesthetics. Disabling
# a theme module should never leave a system non-functional.
{
  hey,
  config,
  lib,
  ...
}: let
  inherit (lib) mkOption;
  inherit (lib.types) float nullOr str;
  inherit (hey.lib) mapModules' mkOpt;

  cfg = config.modules.theme;
in {
  imports = mapModules' ./. import;

  options.modules.theme = {
    active = mkOption {
      type = nullOr str;
      default = null;
      description = ''
        Name of the theme to enable. Hosts should set this declaratively so
        theme selection does not depend on ambient evaluation environment.
      '';
    };

    fonts = {
      mono = {
        name = mkOpt str "Monospace";
        size = mkOpt float 12.0;
      };
      sans = {
        name = mkOpt str "Sans";
        size = mkOpt float 12.0;
      };
      terminal = {
        name = mkOpt str cfg.fonts.mono.name;
        size = mkOpt float (cfg.fonts.mono.size - 2.5);
      };
      icons = {
        name = mkOpt str "Font Awesome 6 Free";
        size = mkOpt float cfg.fonts.sans.size;
      };
    };

    colors = {
      black = mkOpt str "#000000"; # 0
      red = mkOpt str "#FF0000"; # 1
      green = mkOpt str "#00FF00"; # 2
      yellow = mkOpt str "#FFFF00"; # 3
      blue = mkOpt str "#0000FF"; # 4
      magenta = mkOpt str "#FF00FF"; # 5
      cyan = mkOpt str "#00FFFF"; # 6
      silver = mkOpt str "#BBBBBB"; # 7
      grey = mkOpt str "#888888"; # 8
      brightred = mkOpt str "#FF8800"; # 9
      brightgreen = mkOpt str "#00FF80"; # 10
      brightyellow = mkOpt str "#FF8800"; # 11
      brightblue = mkOpt str "#0088FF"; # 12
      brightmagenta = mkOpt str "#FF88FF"; # 13
      brightcyan = mkOpt str "#88FFFF"; # 14
      white = mkOpt str "#FFFFFF"; # 15

      # Color classes
      types = {
        bg = mkOpt str cfg.colors.black;
        fg = mkOpt str cfg.colors.white;
        panelbg = mkOpt str cfg.colors.types.bg;
        panelfg = mkOpt str cfg.colors.types.fg;
        border = mkOpt str cfg.colors.types.bg;
        error = mkOpt str cfg.colors.red;
        warning = mkOpt str cfg.colors.yellow;
        highlight = mkOpt str cfg.colors.white;
        selection = mkOpt str cfg.colors.types.panelbg;
      };
    };
  };
}
