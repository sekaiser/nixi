{
  hey,
  config,
  pkgs,
  lib,
  ...
}: let
  inherit (builtins) toJSON;
  inherit (lib) mkIf optional optionalAttrs;
  inherit (lib.types) attrs listOf nullOr package str;
  inherit (hey.lib) mkBoolOpt' mkOpt';

  cfg = config.modules.editors.zed;
  jsonFormat = pkgs.formats.json {};
in {
  options.modules.editors.zed = {
    enable = mkBoolOpt' false "Whether to manage Zed editor configuration.";
    package = mkOpt' (nullOr package) null "Optional Zed package to install. Leave null when the platform installs Zed outside Nix, for example through Homebrew casks on Darwin.";
    settings = mkOpt' jsonFormat.type {} "Zed settings written to zed/settings.json.";
    keymap = mkOpt' (listOf attrs) [] "Optional Zed keymap entries written to zed/keymap.json when non-empty.";
    tasks = mkOpt' (listOf attrs) [] "Optional Zed task entries written to zed/tasks.json when non-empty.";
    extensions = mkOpt' (listOf str) [] "Desired Zed extension identifiers. Zed still owns extension installation; this manifest lets hey detect drift.";
  };

  config = mkIf cfg.enable {
    user.packages = optional (cfg.package != null) cfg.package;

    home.configFile =
      {
        "zed/settings.json" = {
          text = toJSON cfg.settings;
        };
      }
      // optionalAttrs (cfg.keymap != []) {
        "zed/keymap.json" = {
          text = toJSON cfg.keymap;
        };
      }
      // optionalAttrs (cfg.tasks != []) {
        "zed/tasks.json" = {
          text = toJSON cfg.tasks;
        };
      };

    home.dataFile."hey/zed-extensions.json" = {
      text = toJSON {
        extensions = cfg.extensions;
      };
    };
  };
}
