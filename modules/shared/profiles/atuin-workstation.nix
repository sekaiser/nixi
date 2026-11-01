{
  config,
  lib,
  ...
}: {
  options.modules.profiles.atuin-workstation.enable = lib.mkEnableOption "Atuin workstation preferences";

  config = lib.mkIf config.modules.profiles.atuin-workstation.enable (lib.mkMerge [
    {modules.shell.atuin.enable = lib.mkDefault true;}
    (lib.mkIf config.modules.shell.atuin.enable {
      modules.shell.atuin = {
        disableUpArrow = lib.mkDefault true;
        settings = {
          style = lib.mkDefault "compact";
          inline_height = lib.mkDefault 16;
          enter_accept = lib.mkDefault true;
          filter_mode = lib.mkDefault "global";
          workspaces = lib.mkDefault true;
        };
      };
    })
  ]);
}
