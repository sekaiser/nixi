# Compare the current module against current and optionally proposed package pins.
# Metadata only: invoke with IFD, builders and local jobs disabled.
{
  root,
  candidateRoot ? null,
  includePatchContent ? false,
}: let
  current = builtins.getFlake ("path:" + root);
  proposed =
    if candidateRoot == null
    then null
    else builtins.getFlake ("path:" + candidateRoot);
  systems = ["aarch64-darwin" "aarch64-linux" "x86_64-linux"];
  contexts =
    [
      {
        label = "current";
        inputs = current.inputs;
      }
    ]
    ++ (
      if proposed == null
      then []
      else [
        {
          label = "candidate-not-applied";
          inputs = proposed.inputs;
        }
      ]
    );
  compare = context: system: let
    outputs = current.lib.mkHostFlake {
      inputs = {
        self.outPath = ../checks/fixtures/cli-host;
        nixi = current;
        inherit (context.inputs) nixpkgs nixpkgs-darwin nixpkgs-unstable;
      };
      hosts.review = {
        inherit system;
        module = _: {
          config = {
            user = {
              name = "review";
              home = "/fixture/review";
            };
            home.stateVersion = "26.05";
            system.stateVersion =
              if system == "aarch64-darwin"
              then 6
              else "26.05";
          };
        };
      };
    };
    host =
      if system == "aarch64-darwin"
      then outputs.darwinConfigurations.review
      else outputs.nixosConfigurations.review;
    selected = host.config.modules.editors.emacs.package;
    p = host.pkgs.unstable;
    upstream =
      if system == "aarch64-darwin"
      then p.emacs31
      else p.emacs31-pgtk;
    releaseMode = upstream.override {srcRepo = false;};
    describe = package: {
      inherit (package) version drvPath;
      outputPaths = map (name: toString package.${name}) package.outputs;
      source =
        {
          urls = package.src.urls or [package.src.url];
          hash = package.src.outputHash;
          drvPath = package.src.drvPath;
        }
        // (
          if includePatchContent
          then {output = toString package.src;}
          else {}
        );
      patches = map (patch:
        {
          path = toString patch;
          name = patch.name or (builtins.baseNameOf (toString patch));
          urls =
            patch.urls or (
              if patch ? url
              then [patch.url]
              else []
            );
          hash = patch.outputHash or null;
        }
        // (
          if includePatchContent
          then {
            drvPath = patch.drvPath or null;
            template =
              if patch ? buildPhase
              then toString patch.src
              else null;
            buildPhase = patch.buildPhase or null;
          }
          else {}
        ))
      package.patches;
      nativeBuildInputs = map (x: x.name) package.nativeBuildInputs;
      inherit (package) configureFlags withNativeCompilation withTreeSitter;
      recipeExceptSourceSha256 = builtins.hashString "sha256" (builtins.toJSON (builtins.removeAttrs package.drvAttrs ["src"]));
    };
  in {
    inherit (context) label;
    inherit system;
    nixpkgsUnstableRev = context.inputs.nixpkgs-unstable.rev;
    upstream = describe upstream;
    releaseMode = describe releaseMode;
    selected = describe selected;
    releaseModeRetainsGitSource = releaseMode.src.outPath == upstream.src.outPath;
    selectedRetainsReleaseRecipe = (describe selected).recipeExceptSourceSha256 == (describe releaseMode).recipeExceptSourceSha256;
    sameSelectedSource = selected.src.outPath == upstream.src.outPath;
    sameSelectedDerivation = selected.drvPath == upstream.drvPath;
  };
in
  builtins.concatMap (context: map (compare context) systems) contexts
