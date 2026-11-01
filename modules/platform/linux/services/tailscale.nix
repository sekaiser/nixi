{
  hey,
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkDefault mkIf mkOption optional types;
  inherit (hey.lib) mkBoolOpt';

  cfg = config.modules.services.tailscale;
  contracts = import ../../../../lib/internal/file-contracts.nix {inherit lib;};
  native = config.services.tailscale;
  credentialFile = "/run/credentials/tailscaled-autoconnect.service/nixi-auth-key";
in {
  options.modules.services.tailscale = {
    enable = mkBoolOpt' false "Whether to enable Tailscale with native NixOS authentication and the IP-file helper.";

    keyFile = mkOption {
      type = types.nullOr contracts.runtimeSecretPath;
      default = null;
      description = "Absolute path to a runtime auth-key file, loaded as a systemd credential. Null leaves authentication to native configuration or manual login.";
    };

    useRoutingFeatures = mkOption {
      type = types.enum ["none" "client" "server" "both"];
      default = "client";
      description = "Value passed to services.tailscale.useRoutingFeatures.";
    };

    extraUpFlags = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "Additional flags passed to tailscale up.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = !native.enable || cfg.keyFile == null || (lib.hasPrefix "/" cfg.keyFile && !lib.hasInfix "\n" cfg.keyFile && !lib.hasInfix "\r" cfg.keyFile);
        message = "modules.services.tailscale.keyFile must be an absolute, single-line runtime path.";
      }
    ];

    services.tailscale = {
      enable = mkDefault true;
      openFirewall = mkDefault true;
      useRoutingFeatures = mkDefault cfg.useRoutingFeatures;
      extraUpFlags = mkDefault cfg.extraUpFlags;
      # The pinned native module reads this path in shell code. Keep that path
      # fixed and let systemd load the real (possibly space-containing) filename.
      authKeyFile = mkIf (cfg.keyFile != null) (mkDefault credentialFile);
    };

    systemd.services.tailscaled-autoconnect = mkIf (native.enable && native.authKeyFile != null) {
      # Failed daemon readiness or a temporarily unavailable credential must be
      # retryable. Keep NixOS' notify/readiness protocol and authentication script.
      unitConfig.StartLimitIntervalSec = mkDefault 0;
      serviceConfig = {
        Restart = mkDefault "on-failure";
        RestartSec = mkDefault "5s";
        TimeoutStartSec = mkDefault "2min";
        LoadCredential = mkIf (cfg.keyFile != null && native.authKeyFile == credentialFile) [
          "nixi-auth-key:${lib.replaceStrings ["%"] ["%%"] cfg.keyFile}"
        ];
      };
    };

    systemd.services.tailscale-fetch-ip = mkIf native.enable {
      description = "Fetch Tailscale IP and store it in TAILSCALE_IP format";
      after = ["tailscaled.service"] ++ optional (native.authKeyFile != null) "tailscaled-autoconnect.service";
      wants = ["tailscaled.service"] ++ optional (native.authKeyFile != null) "tailscaled-autoconnect.service";
      # Manual login must not hold up boot waiting for an address. Consumers
      # such as K3s can still explicitly require this helper when they need it.
      wantedBy = optional (native.authKeyFile != null) "multi-user.target";
      path = [native.package pkgs.coreutils];
      unitConfig.StartLimitIntervalSec = mkDefault 0;
      serviceConfig = {
        Type = "oneshot";
        Restart = mkDefault "on-failure";
        RestartSec = mkDefault "5s";
        TimeoutStartSec = mkDefault "2min";
        RemainAfterExit = "yes";
      };
      script = ''
        # An existing interface is not proof that it has an assigned address.
        until IP="$(tailscale ip -4 2>/dev/null)" && [ -n "$IP" ]; do
          sleep 1
        done
        mkdir -p /var/tailscale
        replacement="$(mktemp /var/tailscale/.ip.XXXXXXXXXX)"
        trap 'rm -f -- "$replacement"' EXIT
        printf 'TAILSCALE_IP=%s\n' "$IP" > "$replacement"
        chmod 0644 "$replacement"
        mv -f -- "$replacement" /var/tailscale/ip
      '';
    };
  };
}
