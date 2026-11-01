{
  config,
  lib,
  ...
}: let
  inherit (lib) mkDefault mkEnableOption mkIf mkOption;
  cfg = config.modules.profiles.gitea-tailscale;
  server = config.services.gitea.settings.server;
  backendHost =
    if lib.hasInfix ":" server.HTTP_ADDR
    then "[${server.HTTP_ADDR}]"
    else server.HTTP_ADDR;
in {
  options.modules.profiles.gitea-tailscale = {
    enable = mkEnableOption "Gitea behind Caddy with Tailscale-managed certificates";
    httpsPort = mkOption {
      type = lib.types.port;
      default = 8890;
      description = "Public HTTPS port for the Gitea reverse proxy.";
    };
  };

  config = mkIf cfg.enable {
    modules.services = {
      caddy.enable = mkDefault true;
      gitea.enable = mkDefault true;
      tailscale.enable = mkDefault true;
    };
    assertions = [
      {
        assertion = config.services.caddy.enable && config.services.gitea.enable && config.services.tailscale.enable;
        message = "modules.profiles.gitea-tailscale requires Caddy, Gitea and Tailscale to be enabled.";
      }
    ];

    services.gitea.settings = {
      server = {
        HTTP_ADDR = mkDefault "127.0.0.1";
        HTTP_PORT = mkDefault 3301;
        ROOT_URL = mkDefault "https://${server.DOMAIN}:${toString cfg.httpsPort}/";
      };
      session.COOKIE_SECURE = mkDefault true;
    };
    services.tailscale.permitCertUid = mkDefault config.services.caddy.user;
    services.caddy.virtualHosts."${server.DOMAIN}:${toString cfg.httpsPort}".extraConfig = ''
      reverse_proxy http://${backendHost}:${toString server.HTTP_PORT}
      tls {
        get_certificate tailscale
      }
    '';
    networking.firewall.allowedTCPPorts = [cfg.httpsPort];
  };
}
