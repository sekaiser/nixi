# modules/shared/themes/alucard/default.nix --- a regal dracula-inspired theme
{
  config,
  lib,
  ...
}: let
  inherit (lib) mkIf;

  cfg = config.modules.theme;
in {
  config = mkIf (cfg.active == "alucard") {
    modules = {
      theme = {
        fonts = {
          sans.name = "Fira Sans";
          mono.name = "Fira Code";
        };
        colors = {
          black = "#1E2029";
          red = "#ffb86c";
          green = "#50fa7b";
          yellow = "#f0c674";
          blue = "#61bfff";
          magenta = "#bd93f9";
          cyan = "#8be9fd";
          silver = "#e2e2dc";
          grey = "#5B6268";
          brightred = "#de935f";
          brightgreen = "#0189cc";
          brightyellow = "#f9a03f";
          brightblue = "#8be9fd";
          brightmagenta = "#ff79c6";
          brightcyan = "#0189cc";
          white = "#f8f8f2";

          types.fg = "#bbc2cf";
          types.panelbg = "#21242b";
          types.border = "#1a1c25";
        };
      };

      shell.zsh.rcFiles = [./config/zsh/prompt.zsh];
      shell.tmux.rcFiles = [./config/tmux.conf];
    };

    env = {
      XDG_THEME_CONFIG = "${./config}/";
      BAT_THEME = "Alucard";
    };
  };
}
