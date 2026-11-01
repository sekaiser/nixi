{
  config,
  lib,
  pkgs,
  ...
}: {
  config = lib.mkIf config.modules.profiles.workstation.enable {
    modules.shell.zsh.enable = lib.mkDefault true;
    modules.profiles.primary-user.shell = lib.mkDefault pkgs.zsh;
  };
}
