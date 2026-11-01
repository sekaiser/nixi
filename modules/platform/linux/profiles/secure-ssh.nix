{
  config,
  lib,
  ...
}: {
  options.modules.profiles.secure-ssh.enable = lib.mkEnableOption "key/certificate-only SSH defaults";
  config = lib.mkIf config.modules.profiles.secure-ssh.enable {
    modules.services.ssh = {
      enable = lib.mkDefault true;
      passwordAuthentication = lib.mkDefault false;
    };
    services.openssh.settings = {
      KbdInteractiveAuthentication = lib.mkDefault false;
      PermitRootLogin = lib.mkOverride 900 "no";
    };
  };
}
