{
  lib,
  attrs ? import ../attrs.nix {inherit lib;},
  modules ? import ../modules.nix {inherit lib attrs;},
  nixpkgsLib ? import ../nixpkgs.nix {inherit lib;},
}: let
  inherit (builtins) attrValues elem isAttrs mapAttrs pathExists;
  inherit (lib) filter filterAttrs hasSuffix mkDefault optionalAttrs;
  inherit (attrs) filterMapAttrs mergeAttrs';
  inherit (modules) mapModulesRec';
in rec {
  mkSourcePaths = {
    workspaceRoot,
    frameworkRoot,
  }: let
    frameworkDir =
      if pathExists "${frameworkRoot}/nixi/default.nix"
      then "${frameworkRoot}/nixi"
      else frameworkRoot;
  in {
    dir =
      if workspaceRoot != ""
      then workspaceRoot
      else abort "No or invalid workspace root specified: ${workspaceRoot}";
    inherit frameworkDir;
    binDir = "${frameworkDir}/bin";
    libDir = "${frameworkDir}/lib";
    runtimeDir = "${frameworkDir}/runtime";
    assetsDir = "${frameworkDir}/assets";
    modulesDir = "${frameworkDir}/modules";
    themesDir = "${frameworkDir}/modules/shared/themes";
    hostDir = "${workspaceRoot}/hosts";
  };

  mkPkgs = system: pkgsSrc: overlays:
    nixpkgsLib.mkPkgs {
      inherit system pkgsSrc overlays;
    };

  mkPackageSet = packages: system: pkgs: extraArgs: let
    # Platform selection is definition metadata. Inspecting a derivation's
    # meta.platforms here would evaluate every sibling (including checks).
    wrapped = value: isAttrs value && value ? systems && value ? package;
    selected = filterAttrs (_: value: !(wrapped value) || elem system value.systems) packages;
    packageSet =
      mapAttrs
      (_: value:
        pkgs.callPackage (
          if wrapped value
          then value.package
          else value
        )
        ({self = packageSet;} // extraArgs))
      selected;
  in
    packageSet;

  platformFromSystem = system:
    if hasSuffix "-darwin" system
    then "darwin"
    else if hasSuffix "-linux" system
    then "linux"
    else abort "Unsupported system platform: ${system}";

  # Hosts and flake recipes must see the same platform source, overlays and
  # configuration, including the framework's unstable package namespace.
  mkSystemPkgs = {
    system,
    nixpkgs,
    nixpkgs-darwin ? nixpkgs,
    nixpkgs-unstable ? nixpkgs,
    overlays ? {},
    nixpkgsConfig ? {},
  }:
    nixpkgsLib.mkPkgs {
      inherit system;
      pkgsSrc =
        if platformFromSystem system == "darwin"
        then nixpkgs-darwin
        else nixpkgs;
      config = nixpkgsConfig;
      overlays =
        attrValues overlays
        ++ [
          (_: _: {
            unstable = nixpkgsLib.mkPkgs {
              inherit system;
              pkgsSrc = nixpkgs-unstable;
              overlays = attrValues overlays;
              config = nixpkgsConfig;
            };
          })
        ];
    };

  mkHostConfigurations = {
    systemType,
    pkgsSrc,
    modulesSelector,
    inputsSet,
    hostsSet,
    self,
    hey,
    nixpkgs,
    nixpkgs-unstable,
    overlays,
    apps ? {},
    devShells ? {},
    packages,
    darwin,
    home-manager,
    rootModule ? ../..,
    hostModules ? [],
    nixpkgsConfig ? {},
    pkgsFor ? system:
      mkSystemPkgs {
        inherit system nixpkgs-unstable overlays nixpkgsConfig;
        nixpkgs = pkgsSrc;
      },
  }: let
    # Only include hosts with matching platform. Architecture is handled by the
    # host's own system value, e.g. aarch64-linux or x86_64-linux.
    filterHostsByPlatform = platform: _: {config, ...}: platformFromSystem config.system == platform;

    mkHost = hostName: descriptor: let
      inherit (descriptor) config;
      modules = modulesSelector inputsSet;
      hostArgs = {
        host = hostName;
      };
      sourcePaths = mkSourcePaths {
        workspaceRoot = toString self;
        frameworkRoot = toString hey;
      };

      mkSelf = system:
        self
        // {
          args = hostArgs;
          modules = modulesSelector self.inputs;
          packages = hostPackages;
          devShell = hostDevShells;
          inherit apps;
        }
        // sourcePaths;

      mkHey = system:
        hey
        // {
          args = hostArgs;
          modules = modulesSelector hey.inputs;
          packages = hostPackages;
          devShell = hostDevShells;
          inherit apps;
        }
        // sourcePaths;

      self' = mkSelf config.system;
      hey' = mkHey config.system;

      host =
        config.module {
          args = hostArgs;
          inherit lib modules;
          hey = hey';
        }
        // {
          inherit (config) target;
          system = config.system;
        };

      pkgs = pkgsFor config.system;
      hostPackages = mkPackageSet packages config.system pkgs {};
      hostDevShells = mkPackageSet devShells config.system pkgs {};

      systemModule = {
        nixpkgs.pkgs = pkgs;
        networking.hostName = mkDefault hostArgs.host;
      };
      platformModuleDir = ../../modules/platform/${platformFromSystem host.system};
      hostModuleTail =
        hostModules
        ++ (host.imports or [])
        ++ (mapModulesRec' platformModuleDir import)
        ++ [{modules = host.modules or {};}]
        ++ [(host.config or {}) (host.hardware or {})];

      baseModules = [systemModule rootModule] ++ hostModuleTail;
    in
      if systemType == "darwin"
      then
        darwin.lib.darwinSystem {
          system = host.system;
          specialArgs.self = self';
          specialArgs.hey = hey';
          modules = baseModules;
        }
      else
        nixpkgs.lib.nixosSystem {
          system = host.system;
          specialArgs.self = self';
          specialArgs.hey = hey';
          modules = baseModules;
        };
  in
    filterMapAttrs (filterHostsByPlatform systemType) mkHost hostsSet;

  mkPerSystemOutputs = {
    systems,
    nixpkgs,
    nixpkgs-darwin ? nixpkgs,
    nixpkgs-unstable ? nixpkgs,
    overlays,
    apps,
    checks,
    checkArgs ? {},
    devShells,
    packages,
    nixpkgsConfig ? {},
    pkgsFor ? system:
      mkSystemPkgs {
        inherit system nixpkgs nixpkgs-darwin nixpkgs-unstable overlays nixpkgsConfig;
      },
  }:
    map
    (system: let
      pkgs = pkgsFor system;
      withPkgs = packageAttrs: mkPackageSet packageAttrs system pkgs {};
    in
      # Decide output shape from definitions, not evaluated derivations. In
      # particular, a failing check must not prevent selecting a host output.
      optionalAttrs (apps != {}) {apps.${system} = apps;}
      // optionalAttrs (checks != {}) {checks.${system} = mkPackageSet checks system pkgs checkArgs;}
      // optionalAttrs (devShells != {}) {devShells.${system} = withPkgs devShells;}
      // optionalAttrs (packages != {}) {packages.${system} = withPkgs packages;})
    systems;

  mergeChecks = checksList:
    builtins.zipAttrsWith
    (system: definitions: let
      byName = builtins.zipAttrsWith (_: values: values) definitions;
      duplicates = builtins.attrNames (filterAttrs (_: values: builtins.length values > 1) byName);
    in
      if duplicates != []
      then throw "nixi.lib.mergeChecks: duplicate check names for ${system}: ${builtins.toJSON duplicates}"
      else mapAttrs (_: values: builtins.head values) byName)
    (filter isAttrs checksList);

  mkFlakeOutputs = {
    flake,
    modules,
    nixosConfigurations,
    darwinConfigurations,
    perSystem,
  }:
    (filterAttrs
      (n: _:
        !elem n [
          "apps"
          "bundlers"
          "checks"
          "devices"
          "devShells"
          "hosts"
          "hostModules"
          "nixpkgsConfig"
          "modules"
          "packages"
          "storage"
          "systems"
        ])
      flake)
    // {
      inherit nixosConfigurations darwinConfigurations;
      darwinModules = modules;
      nixosModules = modules;
    }
    // (mergeAttrs' perSystem);
}
