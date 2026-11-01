# Optional workstation preferences; the basic Zsh module stays neutral.
{
  hey,
  lib,
  config,
  pkgs,
  ...
}: let
  inherit (lib) escapeShellArg mkIf;
  cfg = config.modules.profiles.zsh-workstation;
  sourceFiles = files: lib.concatMapStringsSep "\n" (file: "source ${escapeShellArg (toString file)}") files;
  # All executable plugin sources come from the consumer's locked Nixpkgs.
  # Preserve load order; completions are initialized afterwards in .zshrc.
  pluginFiles = with pkgs.unstable; [
    "${fzf}/share/fzf/key-bindings.zsh"
    "${fzf}/share/fzf/completion.zsh"
    "${zsh-vi-mode}/share/zsh-vi-mode/zsh-vi-mode.plugin.zsh"
    "${zsh-fast-syntax-highlighting}/share/zsh/plugins/fast-syntax-highlighting/fast-syntax-highlighting.plugin.zsh"
    "${zsh-autosuggestions}/share/zsh-autosuggestions/zsh-autosuggestions.zsh"
    "${zsh-history-substring-search}/share/zsh-history-substring-search/zsh-history-substring-search.zsh"
    "${zsh-powerlevel10k}/share/zsh-powerlevel10k/powerlevel10k.zsh-theme"
    "${zsh-autopair}/share/zsh/zsh-autopair/autopair.zsh"
  ];
  completionPaths = with pkgs.unstable; [
    "${zsh-completions}/share/zsh/site-functions"
    "${nix-zsh-completions}/share/zsh/site-functions"
  ];
  pluginInit = ''
    fpath=(${lib.concatMapStringsSep " " escapeShellArg completionPaths} $fpath)
    ${sourceFiles pluginFiles}
  '';
  zoxideSafe = pkgs.writeShellScriptBin "zoxide" ''
    # zoxide atomically replaces db.zo with a new file whose mode inherits the
    # caller's umask. Keep one misconfigured shell from making the shared
    # database unreadable to every other shell.
    umask 027
    exec ${pkgs.unstable.zoxide}/bin/zoxide "$@"
  '';
in {
  options.modules.profiles.zsh-workstation.enable = lib.mkEnableOption "the opinionated Zsh workstation preset";
  config = mkIf cfg.enable (lib.mkMerge [
    {modules.shell.zsh.enable = lib.mkDefault true;}
    (mkIf config.modules.shell.zsh.enable {
      modules.shell.zsh = {
        rcInit = lib.mkBefore ''
          (( $+functions[z] )) && unfunction z
          (( $+functions[zi] )) && unfunction zi
          if whence -w hey.cache >/dev/null 2>&1; then
            hey.cache zoxide init zsh --cmd z
            hey.cache ${pkgs.coreutils}/bin/dircolors -b
          else
            eval "$(zoxide init zsh --cmd z)"
            eval "$(${pkgs.coreutils}/bin/dircolors -b)"
          fi
          function z {
            if (( $# == 0 )); then
              __zoxide_zi
            else
              __zoxide_z "$@"
            fi
          }
          function hey_tmux_status_precmd() {
            [[ -n ''${TMUX-} && -n ''${TMUX_PANE-} ]] || return
            (( $+commands[tmux] )) || return
            local tmux_bin=$commands[tmux]

            emulate -L zsh
            setopt no_aliases

            local -a status_fields

            [[ -n ''${DIRENV_DIR-} ]] && status_fields+=('direnv=1')
            [[ -n ''${IN_NIX_SHELL-} ]] && status_fields+=("nix=''${IN_NIX_SHELL}")

            if (( $+commands[git] )) && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
              local branch git_user changed_files added_lines deleted_lines added deleted line git_status
              local -a stat_fields
              branch=$(git branch --show-current 2>/dev/null)
              [[ -n $branch ]] || branch=$(git rev-parse --short HEAD 2>/dev/null)
              git_user=$(git config --get github.user 2>/dev/null)
              [[ -n $git_user ]] || git_user=$(git config --get user.email 2>/dev/null)
              [[ -n $git_user ]] || git_user=$(git config --get user.name 2>/dev/null)
              git_status=$(git status --porcelain --untracked-files=normal 2>/dev/null)
              changed_files=''${#''${(f)git_status}}
              added_lines=0
              deleted_lines=0

              while IFS= read -r line; do
                stat_fields=("''${(@ps:\t:)line}")
                added=''${stat_fields[1]:-}
                deleted=''${stat_fields[2]:-}
                [[ -n $added && -n $deleted ]] || continue
                [[ $added == '-' ]] || (( added_lines += added ))
                [[ $deleted == '-' ]] || (( deleted_lines += deleted ))
              done < <({ git diff --numstat HEAD -- 2>/dev/null || git diff --numstat -- 2>/dev/null; })

              [[ -n $branch ]] && status_fields+=("branch=''${branch}")
              [[ -n $git_user ]] && status_fields+=("user=''${git_user}")
              [[ $changed_files != 0 ]] && status_fields+=("files=''${changed_files}")
              [[ $added_lines != 0 ]] && status_fields+=("added=''${added_lines}")
              [[ $deleted_lines != 0 ]] && status_fields+=("deleted=''${deleted_lines}")
            fi

            "$tmux_bin" set-option -gq "@hey_pane_status_''${TMUX_PANE#%}" "''${(pj:\t:)status_fields}"
          }

          if [[ ( -n ''${TMUX-} || -n ''${TMUX_PANE-} ) && ''${precmd_functions[(Ie)hey_tmux_status_precmd]} -eq 0 ]]; then
            precmd_functions+=(hey_tmux_status_precmd)
          fi
        '';
        envInit = lib.mkBefore ''
          if (( EUID != 0 )); then
            umask 027
          else
            umask 077
          fi
        '';
      };
      home-manager.users.${config.user.name}.home.sessionVariables = {
        HISTFILE = lib.mkDefault "${config.home.stateDir}/zsh/history";
        _ZO_DATA_DIR = lib.mkDefault "${config.home.dataDir}/zoxide";
      };
      programs.zsh = {
        enableCompletion = true;
        enableGlobalCompInit = false;
        promptInit = "";
      };
      # Interactive shell utilities that are useful on every platform.
      user.packages = with pkgs.unstable; [
        bat
        bc
        dust
        eza
        fd
        fzf
        gnumake
        nix-zsh-completions
        ripgrep
        tokei
        vim
        zoxideSafe
      ];

      home.configFile = {
        "zsh/plugins.zsh".text = ''
          NIXI_ZSH_PLUGIN_SET=${builtins.hashString "sha256" pluginInit}
          ${pluginInit}
        '';
        "zsh/.zshrc".source = "${hey.assetsDir}/zsh/.zshrc";
        "zsh/aliases.zsh".source = "${hey.assetsDir}/zsh/aliases.zsh";
        "zsh/completion.zsh".source = "${hey.assetsDir}/zsh/completion.zsh";
        "zsh/completions/_hey".source = "${hey.assetsDir}/zsh/completions/_hey";
        "zsh/keybinds.zsh".source = "${hey.assetsDir}/zsh/keybinds.zsh";
      };
      hey.hooks.reload."80-zsh" = ''
        rm -frv -- ${escapeShellArg "${config.home.cacheDir}/zsh"}/*(DN)
        ${pkgs.coreutils}/bin/rm -f -- ${lib.escapeShellArgs (map (name: "${config.home.configDir}/zsh/${name}.zwc") (import ../../../lib/internal/zsh-cache-files.nix))}
      '';
    })
  ]);
}
