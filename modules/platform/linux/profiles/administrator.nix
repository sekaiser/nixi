{
  config,
  lib,
  ...
}: {
  options.modules.profiles.administrator.enable = lib.mkEnableOption "wheel membership for the selected user";
  config = lib.mkIf config.modules.profiles.administrator.enable {
    user.extraGroups = ["wheel"];
  };
}
