{
  config,
  lib,
  pkgs,
  ...
}: {
  options.modules.profiles.vim-workstation.enable = lib.mkEnableOption "Neovim workstation tools and system-wide vim/v aliases";

  config = lib.mkIf config.modules.profiles.vim-workstation.enable (lib.mkMerge [
    {modules.editors.vim.enable = lib.mkDefault true;}
    (lib.mkIf config.modules.editors.vim.enable {
      user.packages = [pkgs.editorconfig-core-c];
      environment.shellAliases = {
        vim = lib.mkDefault "nvim";
        v = lib.mkDefault "nvim";
      };
    })
  ]);
}
