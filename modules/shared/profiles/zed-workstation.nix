{
  config,
  lib,
  ...
}: let
  defaultSettings = {
    icon_theme = "Kokedera Icons";
    cli_default_open_behavior = "new_window";
    project_panel.dock = "right";
    outline_panel.dock = "right";
    collaboration_panel.dock = "right";
    git_panel.dock = "right";
    agent_buffer_font_size = 18.0;
    agent_ui_font_size = 18.0;
    edit_predictions.mode = "subtle";
    load_direnv = "shell_hook";
    agent = {
      dock = "left";
      model_parameters = [];
    };
    ui_font_size = 18.0;
    buffer_font_size = 18.0;
    theme = {
      mode = "system";
      light = "Kokedera Summer";
      dark = "Kokedera Night";
    };
    languages.YAML = {
      format_on_save = "off";
      remove_trailing_whitespace_on_save = false;
      ensure_final_newline_on_save = false;
    };
  };

  defaultTasks = [
    {
      label = "hey project check";
      command = "hey";
      args = ["project" "check"];
      cwd = "$ZED_WORKTREE_ROOT";
      allow_concurrent_runs = false;
      use_new_terminal = false;
    }
    {
      label = "hey project test";
      command = "hey";
      args = ["project" "test"];
      cwd = "$ZED_WORKTREE_ROOT";
      allow_concurrent_runs = false;
      use_new_terminal = false;
    }
    {
      label = "hey project doctor";
      command = "hey";
      args = ["project" "doctor"];
      cwd = "$ZED_WORKTREE_ROOT";
      allow_concurrent_runs = false;
      use_new_terminal = false;
    }
  ];
in {
  options.modules.profiles.zed-workstation.enable = lib.mkEnableOption "the opinionated Zed workstation preset";
  config = lib.mkIf config.modules.profiles.zed-workstation.enable {
    modules.editors.zed = {
      enable = lib.mkDefault true;
      settings = lib.mapAttrs (_: value: lib.mkDefault value) defaultSettings;
      tasks = lib.mkDefault defaultTasks;
      extensions = lib.mkDefault [
        "catppuccin"
        "csv"
        "docker-compose"
        "dockerfile"
        "flatbuffers"
        "git-firefly"
        "golangci-lint"
        "graphql"
        "html"
        "janet"
        "java"
        "kokedera-icons"
        "kokedera-theme"
        "kotlin"
        "log"
        "lua"
        "make"
        "mermaid"
        "nix"
        "rust-snippets"
        "sql"
        "tokyo-night"
        "toml"
        "zig"
      ];
    };
  };
}
