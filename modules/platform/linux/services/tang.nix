{
  hey,
  config,
  lib,
  ...
}: let
  inherit (lib) mkDefault mkIf;
  inherit (hey.lib) mkBoolOpt';

  cfg = config.modules.services.tang;
  native = config.services.tang;
  numericListeners = lib.all (value: builtins.match "[1-9][0-9]{0,4}" value != null) native.listenStream;
in {
  options.modules.services.tang = {
    enable = mkBoolOpt' false "Whether to enable the Tang network-bound disk encryption server.";
    openFirewall = mkBoolOpt' true "Open the effective numeric Tang TCP listeners. Disable this and configure native firewall rules for addressed or Unix-domain sockets.";
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = !native.enable || native.ipAddressAllow != [];
        message = "modules.services.tang requires an explicit nonempty services.tang.ipAddressAllow.";
      }
      {
        assertion = !native.enable || !cfg.openFirewall || numericListeners;
        message = "Tang automatic firewall rules require numeric listenStream ports; set modules.services.tang.openFirewall = false and configure native firewall rules for other socket addresses.";
      }
    ];
    networking.firewall.allowedTCPPorts = mkIf (native.enable && cfg.openFirewall && numericListeners) (map lib.toInt native.listenStream);
    services.tang = {
      enable = mkDefault true;
      # Upstream already supplies the default port and package.
      # The consuming host must set services.tang.ipAddressAllow explicitly.
      ipAddressAllow = mkDefault [];
    };
  };
}
