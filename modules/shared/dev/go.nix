{
  hey,
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkIf;
  inherit (hey.lib) mkBoolOpt;

  cfg = config.modules.dev.go;
in {
  options.modules.dev.go = {
    enable = mkBoolOpt false;
  };

  config = mkIf cfg.enable {
    user.packages = [
      pkgs.unstable.go
    ];
  };
}
