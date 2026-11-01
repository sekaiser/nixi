# Compatibility names only; native nix-darwin owns option types and defaults.
{
  config,
  lib,
  ...
}: {
  imports = map (name:
    lib.mkAliasOptionModule ["modules" "desktop" "homebrew" name] ["homebrew" name])
  ["enable" "casks" "brews" "taps" "masApps" "whalebrews" "extraConfig"];

  config = lib.mkIf config.homebrew.enable {
    environment.systemPath = ["${config.homebrew.prefix}/sbin"];
    environment.variables.FPATH = "${config.homebrew.prefix}/share/zsh/site-functions:$FPATH";
  };
}
