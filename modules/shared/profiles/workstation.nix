# Optional convenience tools. Trust, identities, and package licensing remain
# consumer policy, even when this profile is enabled.
{
  config,
  lib,
  pkgs,
  ...
}: {
  options.modules.profiles.workstation.enable = lib.mkEnableOption "workstation development tools";
  config = lib.mkIf config.modules.profiles.workstation.enable {
    hey.enable = lib.mkDefault true;
    hey.development.enable = lib.mkDefault true;
    hey.diagnostics.enable = lib.mkDefault true;
    environment.systemPackages = with pkgs;
      [
        unstable.cached-nix-shell
        git
        gnumake
        gnupg
        age
        rsync
        vim
        wget
        ffmpeg
        skaffold
        kustomize
        httpie
        nixpkgs-fmt
        nixd
        sops
      ]
      ++ lib.optionals pkgs.stdenv.isLinux [pkgs.xclip];
  };
}
