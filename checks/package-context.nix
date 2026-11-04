{
  nixi,
  lib,
  runCommand,
  ...
}: let
  security = import ../overlays/security.nix;
  catalogMarker = _: _: {nixiCatalogMarker = "explicit";};
  markerOverlays = {
    a = _: _: {nixiContextTrace = ["a"];};
    b = _: prev: {nixiContextTrace = prev.nixiContextTrace ++ ["b"];};
  };
  # These really are different Nixpkgs trees, not markers on the same input.
  recipe = {
    pkgs,
    writeText,
    ...
  }:
    writeText "package-context" (builtins.toJSON {
      source = toString pkgs.path;
      unstableSource = toString pkgs.unstable.path;
      trace = pkgs.nixiContextTrace or [];
      unstableTrace = pkgs.unstable.nixiContextTrace or [];
      allowUnfree = pkgs.config.allowUnfree;
      unstableAllowUnfree = pkgs.unstable.config.allowUnfree;
      catalogMarker = pkgs.nixiCatalogMarker or null;
      unstableCatalogMarker = pkgs.unstable.nixiCatalogMarker or null;
      openssl = pkgs.openssl.drvPath;
      unstableOpenssl = pkgs.unstable.openssl.drvPath;
    });
  spec = {
    inputs = {
      self.outPath = ./fixtures/cli-host;
      # Both the public and legacy catalogs must be inert until selected.
      nixi =
        nixi
        // {
          overlays = {
            inherit security;
            marker = catalogMarker;
          };
          overlayDefs = {
            inherit security;
            marker = catalogMarker;
          };
        };
    };
    nixpkgsConfig.allowUnfree = true;
    packages.context = recipe;
    devShells.context = recipe;
    checks.context = recipe;
    hosts = lib.genAttrs ["x86_64-linux" "aarch64-linux" "aarch64-darwin"] (system: {
      inherit system;
      module = {hey, ...}: {
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
          environment.variables = {
            NIXI_PACKAGE_CONTEXT = hey.packages.context.text;
            NIXI_SHELL_CONTEXT = hey.devShell.context.text;
          };
        };
      };
    });
  };
  # null exercises the omitted argument, not merely an explicit empty set.
  verifies = inputOverrides: selected: let
    overlays =
      if selected == null
      then {}
      else selected;
    outputs = nixi.lib.mkHostFlake (spec
      // inputOverrides
      // lib.optionalAttrs (selected != null) {inherit overlays;});
    inputs = nixi.inputs // inputOverrides;
  in
    lib.all (system: let
      darwin = lib.hasSuffix "-darwin" system;
      source =
        if darwin
        then inputs.nixpkgs-darwin
        else inputs.nixpkgs;
      expectedPkgs = src:
        import src {
          inherit system;
          config.allowUnfree = true;
          overlays = lib.attrValues overlays;
        };
      base = expectedPkgs source;
      unstable = expectedPkgs inputs.nixpkgs-unstable;
      host =
        outputs.${
          if darwin
          then "darwinConfigurations"
          else "nixosConfigurations"
        }.${
          system
        };
      context = outputs.packages.${system}.context.text;
      expected = {
        source = toString source;
        unstableSource = toString inputs.nixpkgs-unstable;
        trace = base.nixiContextTrace or [];
        unstableTrace = unstable.nixiContextTrace or [];
        allowUnfree = true;
        unstableAllowUnfree = true;
        catalogMarker = base.nixiCatalogMarker or null;
        unstableCatalogMarker = unstable.nixiCatalogMarker or null;
        # Exact upstream derivation identity, not a version-number-only check.
        openssl = base.openssl.drvPath;
        unstableOpenssl = unstable.openssl.drvPath;
      };
    in
      builtins.fromJSON (builtins.unsafeDiscardStringContext context)
      == expected
      && host.pkgs.openssl.drvPath == expected.openssl
      && host.pkgs.unstable.openssl.drvPath == expected.unstableOpenssl
      && host.config.environment.variables.NIXI_PACKAGE_CONTEXT == context
      && host.config.environment.variables.NIXI_SHELL_CONTEXT == context
      && outputs.devShells.${system}.context.text == context
      && outputs.checks.${system}.context.text == context)
    (builtins.attrNames spec.hosts);
  # Opt-in pin behavior remains independently tested without building OpenSSL.
  fixture = version: {
    inherit lib;
    stdenv.fetchurlBoot = args: args;
    openssl_3_6 = {
      inherit version;
      overrideAttrs = f: f {};
    };
  };
  old = (security {} (fixture "3.6.2")).openssl_3_6;
  current = (security {} (fixture fix.fixedVersion)).openssl_3_6;
  newer = (security {} (fixture "3.6.9")).openssl_3_6;
  fix = (builtins.fromJSON (builtins.readFile ../security/overrides.json)).overrides.openssl_3_6;
in
  assert verifies {} null;
  assert verifies {} {};
  assert verifies {} markerOverlays;
  assert verifies {
    nixpkgs = nixi.inputs.nixpkgs-unstable;
    nixpkgs-darwin = nixi.inputs.nixpkgs;
    nixpkgs-unstable = nixi.inputs.nixpkgs-darwin;
  }
  markerOverlays;
  assert verifies {} (markerOverlays
    // {
      security = spec.inputs.nixi.overlays.security;
      marker = spec.inputs.nixi.overlays.marker;
    });
  assert old.version == fix.fixedVersion && old.src == fix.source;
  assert current.version == fix.fixedVersion && current ? overrideAttrs;
  assert newer.version == "3.6.9" && newer ? overrideAttrs;
    runCommand "package-context-check" {} ''touch "$out"''
