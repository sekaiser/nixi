{
  config,
  lib,
  ...
}: let
  cfg = config.modules.services.ssh;
in {
  config = lib.mkIf (cfg.userCertificateRenewal.enable && cfg.userCertificates != {}) {
    systemd.services.nixi-ssh-user-certificates = {
      description = "Renew locally signed SSH user certificates";
      after = cfg.userCertificateRenewal.dependencies;
      requires = cfg.userCertificateRenewal.dependencies;
      serviceConfig = {
        Type = "oneshot";
        ExecStart = config.system.build.nixiUserCertificateRenewal;
        UMask = "0077";
      };
    };
    systemd.timers.nixi-ssh-user-certificates = {
      wantedBy = ["timers.target"];
      timerConfig = {
        OnBootSec = "1m";
        OnUnitActiveSec = "${toString cfg.userCertificateRenewal.intervalSeconds}s";
      };
    };
  };
}
