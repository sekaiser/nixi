{
  hey,
  lib,
  config,
  ...
}: {
  config = lib.mkIf config.hey.enable {
    programs.zsh.shellInit = lib.mkOrder 400 ''
      if [ -e '/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh' ]; then
        . '/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh'
      fi
    '';
    programs.zsh.interactiveShellInit = lib.mkBefore ''
      export fpath=( "${hey.runtimeDir}/zsh" "''${fpath[@]}" )
      autoload -Uz "''${fpath[1]}"/hey.*(.:t)
    '';
  };
}
