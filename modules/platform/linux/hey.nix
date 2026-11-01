{
  hey,
  lib,
  config,
  ...
}: {
  config = lib.mkIf config.hey.enable {
    programs.zsh.shellInit = lib.mkBefore ''
      export fpath=( "${hey.runtimeDir}/zsh" "''${fpath[@]}" )
      autoload -Uz "''${fpath[1]}"/hey.*(.:t)
    '';
  };
}
