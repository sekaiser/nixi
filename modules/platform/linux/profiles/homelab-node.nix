{
  config,
  lib,
  ...
}: let
  inherit (lib) mkEnableOption mkIf;

  cfg = config.modules.profiles.homelab-node;
in {
  options.modules.profiles.homelab-node = {
    enable = mkEnableOption "shared homelab node defaults";
  };

  config = mkIf cfg.enable {
    modules = {
      profiles.homelab-base.enable = true;
    };
  };
}
