# Doom and its packages are built by Nix; only runtime state is writable.
# Inspired by https://github.com/hlissner/dotfiles/blob/master/modules/editors/emacs.nix
{
  hey,
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkIf optionals;
  inherit (lib.types) listOf package path str;
  inherit (hey.lib) mkBoolOpt' mkOpt';
  cfg = config.modules.editors.emacs;
  composeDoomDir = import ../../../lib/internal/compose-doom-dir.nix {inherit pkgs;};
  # The pinned Nixpkgs has a 31.x recipe, but still targets a prerelease.
  # Pin the stable release without updating unrelated system packages.
  baseEmacs =
    (
      if pkgs.stdenv.isDarwin
      then pkgs.unstable.emacs31
      else pkgs.unstable.emacs31-pgtk
    )
    .override {srcRepo = false;};
  emacs31 = baseEmacs.overrideAttrs (old: {
    version = "31.1";
    src = pkgs.unstable.fetchurl {
      url = "mirror://gnu/emacs/emacs-31.1.tar.xz";
      hash = "sha256-HaV5DZWAyBkytb9wBjMRRGjaezQS1p+qdn2uv5dPRYY=";
    };
    meta =
      old.meta
      // {
        changelog = "https://www.gnu.org/savannah-checkouts/gnu/emacs/news/NEWS.31.1";
      };
  });
  doom = hey.inputs.doom-emacs.lib.doomFromPackages pkgs.unstable {
    emacs = cfg.package;
    inherit (cfg) doomLocalDir;
    doomDir = composeDoomDir {inherit (cfg) doomDir extraConfig;};
    experimentalFetchTree = true;
    # Native Tree-sitter grammars must be added explicitly to Emacs' load path.
    extraPackages = epkgs: [epkgs.treesit-grammars.with-all-grammars];
    extraBinPackages =
      dependencies
      ++ cfg.extraPackages
      ++ optionals cfg.latex [pkgs.texlive.combined.scheme-medium];
  };
  dependencies = with pkgs; [
    git
    ripgrep
    fd
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
  ];
in {
  options.modules.editors.emacs = {
    enable = mkBoolOpt' false "Whether to install declaratively built Doom Emacs and its external tools.";
    package = mkOpt' package emacs31 "Emacs 31.1: native Cocoa on Darwin, PGTK on Linux. Uses the pinned Nixpkgs 31.x recipe with the stable release source, without additional Emacs Plus patches.";
    doomDir = mkOpt' path ../../../assets/doom-minimal "Versioned Doom configuration directory bundled into the Nix build. No workstation preferences by default.";
    extraConfig = mkOpt' lib.types.lines "" "Emacs Lisp appended after the selected Doom config.el. Stored in Nix outputs: never include secrets or import private notes as Nix paths.";
    doomLocalDir = mkOpt' str "${config.home.dataDir}/nix-doom" "Writable Doom runtime state, separate from the immutable configuration and packages.";
    finalPackage = lib.mkOption {
      type = package;
      readOnly = true;
      description = "The complete Nix-built Emacs with Doom.";
    };
    latex = mkBoolOpt' false "Whether to install the medium TeX Live distribution for LaTeX and Org previews.";
    extraPackages = mkOpt' (listOf package) [] "Additional system tools used by enabled Doom modules.";
  };

  config = mkIf cfg.enable {
    modules.editors.emacs.finalPackage = doom.emacsWithDoom;
    # nix-darwin exposes system package bundles in /Applications/Nix Apps.
    # User packages alone do not populate that collection. Use Doom's wrapped
    # bundle so Finder launches the same configuration as the terminal.
    environment.systemPackages = optionals pkgs.stdenv.isDarwin [cfg.finalPackage];
    # Shell modules may already provide these tools from another Nixpkgs input.
    user.packages =
      [cfg.finalPackage]
      ++ map lib.lowPrio dependencies
      ++ optionals pkgs.stdenv.isLinux [pkgs.binutils]
      ++ optionals cfg.latex [pkgs.texlive.combined.scheme-medium]
      ++ cfg.extraPackages;

    environment.shellAliases = {
      e = "emacsclient --alternate-editor=emacs --no-wait";
      et = "emacsclient --alternate-editor=emacs --tty";
      emacs-debug = "emacs --debug-init";
    };
    fonts.packages = [pkgs.nerd-fonts.symbols-only];
  };
}
