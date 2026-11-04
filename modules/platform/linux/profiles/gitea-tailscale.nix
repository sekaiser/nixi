{
  config,
  lib,
  ...
}: let
  inherit (lib) mkDefault mkEnableOption mkIf mkMerge mkOption;
  cfg = config.modules.profiles.gitea-tailscale;
  server = config.services.gitea.settings.server;
  backendHost =
    if lib.hasInfix ":" server.HTTP_ADDR
    then "[${server.HTTP_ADDR}]"
    else server.HTTP_ADDR;
  tailnetOnly = cfg.exposure == "tailnet";
  siteName = "${server.DOMAIN}:${toString cfg.httpsPort}";
  listeners = config.services.caddy.virtualHosts.${siteName}.listenAddresses;
  unbracket = value:
    if lib.hasPrefix "[" value && lib.hasSuffix "]" value
    then lib.removeSuffix "]" (lib.removePrefix "[" value)
    else value;
  tailnetAddress = value: let
    address = lib.toLower (unbracket value);
    octets = lib.splitString "." address;
    number = part: let
      result = builtins.tryEval (builtins.fromJSON part);
    in
      if result.success && builtins.isInt result.value
      then result.value
      else -1;
    ipv4 =
      builtins.length octets
      == 4
      && lib.all (part: builtins.match "[0-9]{1,3}" part != null && number part >= 0 && number part <= 255) octets
      && builtins.head octets == "100"
      && number (builtins.elemAt octets 1) >= 64
      && number (builtins.elemAt octets 1) <= 127;
    groups = lib.filter (part: part != "") (lib.splitString ":" address);
    compressed = lib.hasInfix "::" address;
    ipv6 =
      lib.hasPrefix "fd7a:115c:a1e0:" address
      && !lib.hasInfix ":::" address
      && builtins.length (lib.splitString "::" address) <= 2
      && lib.all (part: builtins.match "[0-9a-f]{1,4}" part != null) groups
      && (
        if compressed
        then builtins.length groups < 8
        else builtins.length groups == 8
      )
      && (!lib.hasSuffix ":" address || lib.hasSuffix "::" address);
  in
    ipv4 || ipv6;
  formatAddress = address:
    if lib.hasInfix ":" address && !lib.hasPrefix "[" address
    then "[${address}]"
    else address;
in {
  options.modules.profiles.gitea-tailscale = {
    enable = mkEnableOption "Gitea behind Caddy with Tailscale-managed certificates";
    httpsPort = mkOption {
      type = lib.types.port;
      default = 8890;
      description = "HTTPS port for the Gitea reverse proxy. Exposure is selected separately.";
    };
    exposure = mkOption {
      type = lib.types.enum ["tailnet" "public"];
      default = "tailnet";
      description = "Tailnet mode requires explicit Tailscale listen addresses and opens the port only on its interface. Public mode explicitly permits a global HTTPS port opening.";
    };
    listenAddresses = mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "Tailscale IPv4/IPv6 addresses assigned to this host. Required for tailnet exposure; wildcard listeners are rejected. Public mode may leave the native listener unrestricted.";
    };
  };

  config = mkIf cfg.enable {
    modules.profiles.gitea-compatibility.enable = mkDefault true;
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
      {
        assertion = !tailnetOnly || (listeners != [] && lib.all tailnetAddress listeners);
        message = "gitea-tailscale tailnet exposure requires explicit Tailscale IPv4/IPv6 listenAddresses, including after native overrides.";
      }
      {
        assertion =
          !tailnetOnly
          || (config.networking.firewall.enable
            && !config.services.caddy.openFirewall
            && !(lib.elem cfg.httpsPort config.networking.firewall.allowedTCPPorts)
            && !(lib.any (range: range.from <= cfg.httpsPort && range.to >= cfg.httpsPort) config.networking.firewall.allowedTCPPortRanges));
        message = "gitea-tailscale tailnet exposure requires the firewall and forbids Caddy/global grants for its HTTPS port. Choose public exposure explicitly for a public listener.";
      }
      {
        assertion = !tailnetOnly || lib.elem server.HTTP_ADDR ["127.0.0.1" "::1"];
        message = "gitea-tailscale tailnet exposure requires a loopback Gitea backend.";
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
    services.caddy.virtualHosts.${siteName} = {
      listenAddresses = mkDefault (map formatAddress cfg.listenAddresses);
      extraConfig = ''
        reverse_proxy http://${backendHost}:${toString server.HTTP_PORT}
        tls {
          get_certificate tailscale
        }
      '';
    };
    networking.firewall = mkMerge [
      (mkIf tailnetOnly {interfaces.${config.services.tailscale.interfaceName}.allowedTCPPorts = [cfg.httpsPort];})
      (mkIf (!tailnetOnly) {allowedTCPPorts = [cfg.httpsPort];})
    ];
  };
}
