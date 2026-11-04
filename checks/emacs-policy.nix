{
  nixi,
  lib,
  runCommand,
  ...
}: let
  # Exercise the real module graph and package selection without Doom's IFD or
  # foreign Emacs builds. This records constructor arguments, not application
  # behavior; real native builds, grammar loading and GUI launch remain gates.
  fixture = runCommand "doom-policy-fixture" {} ''mkdir -p "$out"'';
  grammar = runCommand "treesit-policy-fixture" {} ''mkdir -p "$out"'';
  customEmacs = runCommand "custom-emacs-policy-fixture" {} ''mkdir -p "$out"'';
  flymakeSource = runCommand "flymake-1.4.7.tar" {} ''touch "$out"'';
  flymakeFixture = runCommand "flymake-guard-policy-fixture" {
    version = "1.4.7";
    src = flymakeSource;
    dontUnpack = true;
    preInstall = "flymake-policy-pre-install";
    installPhase = ''elpa2nix-install-package "$src"'';
    postInstall = "flymake-policy-post-install";
    nativeBuildInputs = [grammar];
    buildInputs = [customEmacs];
  } ''mkdir -p "$out"'';
  flymakeGuardPatch = ../packages/flymake-trusted-backends.patch;
  inheritedFlymakePatch = ../packages/emacs-tramp-user-full-match.patch;
  # Metadata contract only: the compiled guard test establishes tar contents
  # and behavior. ELPA installs from src while skipping stdenv unpacking.
  flymakeGuardContract = override: let
    withPatches = flymakeFixture.overrideAttrs (_: {patches = [inheritedFlymakePatch];});
    noPatchesProbe = flymakeFixture.overrideAttrs (old: {
      passthru.originallyHasPatches = old ? patches;
    });
    matches = original: let
      result = override {} {flymake = original;};
      selected = result.flymake;
      prepared = selected.src;
      recipe = package: builtins.toJSON (builtins.removeAttrs package.drvAttrs ["src"]);
    in
      builtins.attrNames result
      == ["flymake"]
      && lib.isDerivation prepared
      && prepared.drvPath != original.src.drvPath
      && prepared.name == original.src.name
      && lib.hasSuffix ".tar" prepared.name
      && prepared ? src
      && toString prepared.src == toString original.src
      && prepared ? guardPatch
      && toString prepared.guardPatch == toString flymakeGuardPatch
      && recipe selected == recipe original;
  in
    !noPatchesProbe.originallyHasPatches
    && matches withPatches
    && matches flymakeFixture;
  unguardedFlymake = _self: super: {flymake = super.flymake;};
  patchesOnlyFlymake = _self: super: {
    flymake = super.flymake.overrideAttrs (old: {
      patches = (old.patches or []) ++ [flymakeGuardPatch];
    });
  };
  # Synthetic prepared metadata lets each negative control isolate dropped
  # inherited patches, changed hooks or changed dependency inputs.
  changedInheritedFlymake = changes: _self: super: {
    flymake = super.flymake.overrideAttrs (old:
      {
        src = runCommand old.src.name {
          src = old.src;
          guardPatch = flymakeGuardPatch;
        } ''touch "$out"'';
      }
      // changes);
  };
  flymakeGuardRegressions = [
    unguardedFlymake
    patchesOnlyFlymake
    (changedInheritedFlymake {patches = [];})
    (changedInheritedFlymake {postInstall = "";})
    (changedInheritedFlymake {nativeBuildInputs = [];})
  ];
  outputs = nixi.lib.mkHostFlake {
    inputs = {
      self.outPath = ./fixtures/cli-host;
      inherit nixi;
      doom-emacs.lib.doomFromPackages = _: args: {
        emacsWithDoom = fixture // {captured = args;};
      };
    };
    hosts = lib.genAttrs ["x86_64-linux" "aarch64-linux" "aarch64-darwin"] (system: {
      inherit system;
      module = _: {
        config = {
          user = {
            name = "alice";
            home = "/fixture/alice";
          };
          home.stateVersion = "26.05";
          system.stateVersion =
            if lib.hasSuffix "-darwin" system
            then 6
            else "26.05";
        };
      };
    });
  };
  hosts = builtins.attrValues outputs.nixosConfigurations ++ builtins.attrValues outputs.darwinConfigurations;
  sourceContract = pkgs: package: let
    upstream =
      if pkgs.stdenv.isDarwin
      then pkgs.unstable.emacs31
      else pkgs.unstable.emacs31-pgtk;
    releaseMode = upstream.override {srcRepo = false;};
    # The only recipe changes are the release archive and reviewed local patch.
    # Retain all upstream patches, hooks, dependencies and platform flags.
    expected = releaseMode.overrideAttrs (old: {
      patches = old.patches ++ [
        ../packages/emacs-tramp-user-full-match.patch
        ../packages/emacs-gnutls-literal-trustfiles.patch
      ];
    });
    recipe = drv: builtins.toJSON (builtins.removeAttrs drv.drvAttrs ["src"]);
    flags = package.configureFlags;
  in
    package.version
    == "31.1"
    && (package.src.urls or []) == ["mirror://gnu/emacs/emacs-31.1.tar.xz"]
    && package.src.outputHash == "sha256-HaV5DZWAyBkytb9wBjMRRGjaezQS1p+qdn2uv5dPRYY="
    && package.src.outPath != releaseMode.src.outPath
    && recipe package == recipe expected
    && package.withNativeCompilation
    && package.withTreeSitter
    && lib.elem "--with-native-compilation" flags
    && lib.elem "--with-tree-sitter" flags
    && (
      if pkgs.stdenv.isDarwin
      then lib.elem "--with-ns" flags && !(lib.elem "--with-pgtk" flags)
      else lib.elem "--with-pgtk" flags && !(lib.elem "--with-ns" flags)
    );
  verifies = host: let
    extend = settings: host.extendModules {modules = [settings];};
    minimal = extend {modules.editors.emacs.enable = true;};
    preset = extend {modules.profiles.doom-workstation.enable = true;};
    disabled = map (value:
      preset.extendModules {
        modules = [{modules.editors.emacs.enable = value;}];
      }) [false (lib.mkForce false)];
    custom = preset.extendModules {
      modules = [
        {
          modules.editors.emacs = {
            package = customEmacs;
            extraPackages = [host.pkgs.hello];
            doomDir = lib.mkForce ../assets/doom-minimal;
            doomLocalDir = "/fixture/retained-runtime";
          };
          environment.shellAliases.e = "consumer-editor";
        }
      ];
    };
    latex = minimal.extendModules {modules = [{modules.editors.emacs.latex = true;}];};
    packages = variant: variant.config.users.users.alice.packages;
    names = map lib.getName;
    added = variant: lib.sort builtins.lessThan (lib.subtractLists (names (packages host)) (names (packages variant)));
    sorted = values: lib.sort builtins.lessThan (names values);
    captured = variant: variant.config.modules.editors.emacs.finalPackage.captured;
    selected = minimal.config.modules.editors.emacs.package;
    # Negative controls ensure the contract catches source, patch, build-mode
    # and GUI regressions rather than passing on matching version labels.
    sourceRegressions = [
      (selected.overrideAttrs (_: {src = host.pkgs.unstable.emacs31.src;}))
      (selected.overrideAttrs (_: {patches = [];}))
      (selected.overrideAttrs (old: {nativeBuildInputs = old.nativeBuildInputs ++ [host.pkgs.unstable.autoreconfHook];}))
      (selected.overrideAttrs (old: {configureFlags = builtins.filter (flag: flag != "--with-ns" && flag != "--with-pgtk") old.configureFlags;}))
    ];
    # The former helper collection is retained exactly by the explicit preset.
    essential = with host.pkgs; [git ripgrep fd];
    helpers = with host.pkgs; [
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
    linuxTools = lib.optionals host.pkgs.stdenv.isLinux [host.pkgs.binutils];
    unchanged = variant:
      added variant
      == []
      && variant.config.environment.shellAliases == host.config.environment.shellAliases
      && variant.config.fonts.packages == host.config.fonts.packages
      && !(lib.any (p: lib.getName p == "doom-policy-fixture") variant.config.environment.systemPackages);
    preservesWiring = variant: let
      cfg = variant.config.modules.editors.emacs;
      args = captured variant;
      grammars = args.extraPackages {treesit-grammars.with-all-grammars = grammar;};
    in
      args.emacs.drvPath
      == cfg.package.drvPath
      && args.doomLocalDir == cfg.doomLocalDir
      && builtins.length grammars == 1
      && (builtins.head grammars).drvPath == grammar.drvPath
      && args.experimentalFetchTree
      && args ? emacsPackageOverrides
      && flymakeGuardContract args.emacsPackageOverrides
      && lib.count (p: lib.getName p == "doom-policy-fixture") (packages variant) == 1
      && lib.count (p: lib.getName p == "doom-policy-fixture") variant.config.environment.systemPackages
      == (
        if host.pkgs.stdenv.isDarwin
        then 1
        else 0
      );
  in
    sourceContract host.pkgs selected
    && lib.all (package: !(sourceContract host.pkgs package)) sourceRegressions
    && added minimal
    == sorted ([fixture] ++ essential)
    && minimal.config.environment.shellAliases == host.config.environment.shellAliases
    && minimal.config.fonts.packages == host.config.fonts.packages
    && names (captured minimal).extraBinPackages == names essential
    && lib.hasSuffix "/assets/doom-minimal" (toString minimal.config.modules.editors.emacs.doomDir)
    && added preset == sorted ([fixture] ++ essential ++ helpers ++ linuxTools)
    && names (captured preset).extraBinPackages == names (essential ++ helpers)
    && lib.all (p: (p.meta.priority or 5) == 10) (lib.filter (p: builtins.elem (lib.getName p) (names (essential ++ helpers))) (packages preset))
    && preset.config.environment.shellAliases.e == "emacsclient --alternate-editor=emacs --no-wait"
    && preset.config.environment.shellAliases.et == "emacsclient --alternate-editor=emacs --tty"
    && preset.config.environment.shellAliases.emacs-debug == "emacs --debug-init"
    && preset.config.fonts.packages == host.config.fonts.packages ++ [host.pkgs.nerd-fonts.symbols-only]
    && lib.hasSuffix "/assets/doom" (toString preset.config.modules.editors.emacs.doomDir)
    && preset.config.modules.editors.emacs.doomLocalDir == preset.config.home.dataDir + "/nix-doom"
    && lib.all unchanged disabled
    && custom.config.environment.shellAliases.e == "consumer-editor"
    && names (captured custom).extraBinPackages == names (essential ++ helpers ++ [host.pkgs.hello])
    && (captured custom).doomLocalDir == "/fixture/retained-runtime"
    && lib.hasSuffix "/assets/doom-minimal" (toString (captured custom).doomDir)
    && added latex == sorted ([fixture] ++ essential ++ [host.pkgs.texlive.combined.scheme-medium])
    && names (captured latex).extraBinPackages == names (essential ++ [host.pkgs.texlive.combined.scheme-medium])
    && lib.all preservesWiring [minimal preset custom latex];
in
  assert lib.assertMsg (lib.all (override: !(flymakeGuardContract override)) flymakeGuardRegressions) "Flymake guard policy negative controls failed";
  assert lib.assertMsg (lib.all verifies hosts) "Emacs core/workstation policy matrix failed";
    runCommand "emacs-policy-check" {} ''touch "$out"''
