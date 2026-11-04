{
  config,
  lib,
  pkgs,
  ...
}: {
  options.modules.profiles.doom-workstation.enable = lib.mkEnableOption "the opinionated Doom workstation configuration";
  config = lib.mkIf config.modules.profiles.doom-workstation.enable (lib.mkMerge [
    {
      modules.editors.emacs = {
        enable = lib.mkDefault true;
        doomDir = lib.mkDefault ../../../assets/doom;
      };
    }
    (lib.mkIf config.modules.editors.emacs.enable {
      # Retain the workstation collection and its low-priority user packages.
      # Put it before consumer additions, as in the former core wrapper PATH.
      modules.editors.emacs.extraPackages = lib.mkBefore (map lib.lowPrio (with pkgs; [
        gnutls
        coreutils
        findutils
        gnumake
        cmake
        libtool
        imagemagick
        zstd
        (aspellWithDicts (ds: with ds; [en en-computers en-science]))
        ffmpegthumbnailer
        mediainfo
        vips
        editorconfig-core-c
        sqlite
        automake
        autoconf
        pkg-config
        libpng
        zlib
        poppler
        clang-tools
        age
      ]));
      user.packages = lib.optionals pkgs.stdenv.isLinux [pkgs.binutils];
      environment.shellAliases = lib.mapAttrs (_: lib.mkDefault) {
        e = "emacsclient --alternate-editor=emacs --no-wait";
        et = "emacsclient --alternate-editor=emacs --tty";
        emacs-debug = "emacs --debug-init";
      };
      fonts.packages = [pkgs.nerd-fonts.symbols-only];
    })
  ]);
}
