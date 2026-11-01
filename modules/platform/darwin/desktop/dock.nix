{
  config,
  lib,
  ...
}: let
  inherit (lib) filter mkEnableOption mkIf mkOption types;
  cfg = config.modules.desktop.dock;
in {
  options.modules.desktop.dock = {
    enable = mkEnableOption "declarative Dock entries via nix-darwin";
    entries = mkOption {
      default = null;
      description = "Dock layout. null leaves the existing layout alone; an explicit empty list clears it. For advanced tiles, use system.defaults.dock directly.";
      type = types.nullOr (types.listOf (types.submodule {
        options = {
          path = mkOption {type = types.str;};
          section = mkOption {
            type = types.enum ["apps" "others"];
            default = "apps";
          };
          options = mkOption {
            type = types.listOf types.str;
            default = [];
            description = "Legacy dockutil flags, no longer supported. Use native system.defaults.dock options instead.";
          };
        };
      }));
    };
  };

  config = mkIf (cfg.enable && cfg.entries != null) {
    assertions = [
      {
        assertion = lib.all (entry: entry.options == []) cfg.entries;
        message = "modules.desktop.dock.entries no longer accepts dockutil flags; migrate to system.defaults.dock.persistent-apps/persistent-others.";
      }
    ];
    system.defaults.dock = {
      persistent-apps = map (entry: entry.path) (filter (entry: entry.section == "apps") cfg.entries);
      persistent-others = map (entry: entry.path) (filter (entry: entry.section == "others") cfg.entries);
    };
  };
}
