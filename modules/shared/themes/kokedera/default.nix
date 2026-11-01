# modules/shared/themes/kokedera/default.nix --- Kokedera theme
{
  config,
  lib,
  ...
}: let
  inherit (lib) mkIf;

  cfg = config.modules.theme;
in {
  config = mkIf (cfg.active == "kokedera") {
    modules = {
      theme = {
        fonts = {
          sans.name = "Fira Sans";
          mono.name = "Fira Code";
        };
        colors = {
          black = "#1a2619";
          red = "#c45a5a";
          green = "#5ab85a";
          yellow = "#bfa243";
          blue = "#3d9970";
          magenta = "#9a7abf";
          cyan = "#5a9e8f";
          silver = "#c8d8b8";
          grey = "#4a5a44";
          brightred = "#d47070";
          brightgreen = "#7ec46c";
          brightyellow = "#d4c88e";
          brightblue = "#5ab89e";
          brightmagenta = "#b49ad4";
          brightcyan = "#7ab8a8";
          white = "#dae8ca";

          types = {
            bg = "#121a11";
            fg = "#c8d8b8";
            panelbg = "#151e14";
            panelfg = "#c8d8b8";
            border = "#3a4a35";
            error = "#c45a5a";
            warning = "#bfa243";
            highlight = "#7ec46c";
            selection = "#2a3d26";
          };
        };
      };

      shell.zsh.rcFiles = [
        ./config/zsh/colors.zsh
        ../alucard/config/zsh/prompt.zsh
      ];
      shell.tmux.rcFiles = [./config/tmux.conf];
    };
  };
}
