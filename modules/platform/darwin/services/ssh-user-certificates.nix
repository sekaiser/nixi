{
  config,
  lib,
  ...
}: let
  cfg = config.modules.services.ssh;
in {
  config = lib.mkIf (cfg.userCertificateRenewal.enable && cfg.userCertificates != {}) {
    launchd.daemons.nixi-ssh-user-certificates.serviceConfig = {
      ProgramArguments = ["${config.system.build.nixiUserCertificateRenewal}"];
      RunAtLoad = true;
      StartInterval = cfg.userCertificateRenewal.intervalSeconds;
      UserName = "root";
    };
  };
}
