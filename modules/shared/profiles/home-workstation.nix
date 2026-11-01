{
  config,
  lib,
  ...
}: {
  options.modules.profiles.home-workstation.enable = lib.mkEnableOption "the custom workstation desktop-directory layout";
  config = lib.mkIf config.modules.profiles.home-workstation.enable {
    home-manager.users.${config.user.name}.home.sessionVariables = {
      XDG_FAKE_HOME = lib.mkDefault config.home.fakeDir;
      XDG_DESKTOP_DIR = lib.mkDefault config.home.fakeDir;
    };
  };
}
