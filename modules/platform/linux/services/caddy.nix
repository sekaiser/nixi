{
  hey,
  config,
  lib,
  ...
}: let
  inherit (lib) mkIf;
  inherit (hey.lib) mkBoolOpt';

  cfg = config.modules.services.caddy;
in {
  options.modules.services.caddy = {
    enable = mkBoolOpt' false "Whether to enable Caddy reverse proxy configuration.";
  };

  config = mkIf cfg.enable {
    services.caddy = {
      enable = lib.mkDefault true;
      openFirewall = lib.mkDefault false;
    };
  };
}
