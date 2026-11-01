{
  config,
  lib,
  ...
}: {
  options.modules.profiles.doom-workstation.enable = lib.mkEnableOption "the opinionated Doom workstation configuration";
  config = lib.mkIf config.modules.profiles.doom-workstation.enable {
    modules.editors.emacs = {
      enable = lib.mkDefault true;
      doomDir = lib.mkDefault ../../../assets/doom;
    };
  };
}
