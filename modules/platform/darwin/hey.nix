{
  hey,
  lib,
  config,
  ...
}: {
  config = lib.mkIf config.hey.enable {
    # nix-darwin initializes Nix and orders its managed profiles before this
    # hook. Re-sourcing an installer script here would prepend its legacy
    # client over the selected system package.
    programs.zsh.interactiveShellInit = lib.mkBefore ''
      export fpath=( "${hey.runtimeDir}/zsh" "''${fpath[@]}" )
      autoload -Uz "''${fpath[1]}"/hey.*(.:t)
    '';
  };
}
