# lib/nix.nix --- syntax sugar for flakes
#
# Host composition and framework outputs share a small, explicit contract.
{
  lib,
  attrs,
  hostlib ? import ./hostlib.nix {inherit lib;},
  nixpkgsLib ? import ./nixpkgs.nix {inherit lib;},
  modules,
  flake ?
    import ./flake {
      inherit lib attrs modules nixpkgsLib;
    },
  darwin,
  home-manager,
}: let
  inherit (builtins) attrValues mapAttrs typeOf;
  inherit (attrs) filterMapAttrs;
  inherit (flake) mkFlakeOutputs mkHostConfigurations mkPerSystemOutputs;
  inherit (lib) unique;

  # Both public adapters lower to this builder. Normalization, input precedence
  # and framework-only check arguments stay at their respective API boundaries.
  compose = {
    spec,
    inputs,
    self,
    hey,
    hosts,
    systems,
    nixpkgs,
    nixpkgs-darwin,
    nixpkgs-unstable,
    darwin,
    home-manager,
    apps,
    checks,
    checkArgs,
    devShells,
    modules,
    overlays,
    packages,
    hostModules,
    nixpkgsConfig,
  }: let
    pkgsFor = system:
      flake.mkSystemPkgs {
        inherit system nixpkgs nixpkgs-darwin nixpkgs-unstable overlays nixpkgsConfig;
      };
    mkHosts = systemType: pkgsSrc: output:
      mkHostConfigurations {
        inherit systemType pkgsSrc pkgsFor;
        modulesSelector = filterMapAttrs (_: input: builtins.isAttrs input && builtins.hasAttr output input) (_: input: input.${output});
        inputsSet = inputs;
        hostsSet = hosts;
        inherit self hey nixpkgs nixpkgs-unstable overlays apps devShells packages darwin home-manager hostModules nixpkgsConfig;
      };
  in
    mkFlakeOutputs {
      flake = spec;
      inherit modules;
      darwinConfigurations = mkHosts "darwin" nixpkgs-darwin "darwinModules";
      nixosConfigurations = mkHosts "linux" nixpkgs "nixosModules";
      perSystem = mkPerSystemOutputs {
        inherit systems nixpkgs overlays apps checks checkArgs devShells packages nixpkgsConfig pkgsFor;
      };
    };
in {
  mkApp = program: {
    inherit program;
    type = "app";
  };

  # Workspace/framework entrypoint. External host flakes should use
  # mkHostFlake. See docs/flake-api.md for both public contracts.
  mkFlake = {
    self,
    hey ? self,
    nixpkgs ? hey.inputs.nixpkgs,
    nixpkgs-darwin ? hey.inputs.nixpkgs-darwin,
    nixpkgs-unstable ? hey.inputs.nixpkgs-unstable or nixpkgs,
    ...
  } @ inputs: {
    apps ? {},
    checks ? {},
    devShells ? {},
    hosts ? {},
    hostModules ? [],
    nixpkgsConfig ? {},
    modules ? {},
    overlays ? {},
    packages ? {},
    storage ? {},
    systems,
    templates ? {},
    ...
  } @ flake:
    compose {
      spec = flake;
      inherit inputs self hey systems nixpkgs nixpkgs-darwin nixpkgs-unstable darwin home-manager apps checks devShells modules overlays packages hostModules nixpkgsConfig;
      hosts = mapAttrs hostlib.normalizeHostDescriptor hosts;
      checkArgs = {
        inherit hey;
        nixi = {
          inherit (flake) lib;
          inherit inputs;
          outPath = toString ../.;
        };
      };
    };

  # Stable consumer entrypoint for external host and fleet flakes.
  mkHostFlake = {
    inputs,
    hosts,
    self ? inputs.self or inputs.nixi,
    nixi ? inputs.nixi or self,
    hey ? nixi,
    nixpkgs ? inputs.nixpkgs or nixi.inputs.nixpkgs,
    nixpkgs-darwin ? inputs.nixpkgs-darwin or nixi.inputs.nixpkgs-darwin or nixpkgs,
    nixpkgs-unstable ? inputs.nixpkgs-unstable or nixi.inputs.nixpkgs-unstable or nixpkgs,
    darwin ? inputs.darwin or nixi.inputs.darwin or null,
    home-manager ? inputs.home-manager or nixi.inputs.home-manager or null,
    apps ? {},
    checks ? {},
    devShells ? {},
    modules ? {},
    overlays ? {},
    packages ? {},
    hostModules ? [],
    nixpkgsConfig ? {},
    systems ? null,
    ...
  } @ hostFlake: let
    normalizeHost = hostName: descriptor: let
      descriptorType = typeOf descriptor;
      descriptorWithConfig =
        if descriptor ? path && descriptor ? config
        then descriptor
        else if descriptorType == "path"
        then {
          path = descriptor;
          config = hostlib.importHostDescriptor descriptor;
        }
        else {
          path = descriptor.path or "<inline:${hostName}>";
          config = descriptor;
        };
      config =
        if descriptorWithConfig.config ? module && typeOf descriptorWithConfig.config.module == "path"
        then descriptorWithConfig.config // {module = import descriptorWithConfig.config.module;}
        else descriptorWithConfig.config;
    in
      hostlib.normalizeHostDescriptor hostName (descriptorWithConfig // {inherit config;});

    normalizedHosts = mapAttrs normalizeHost hosts;
    hostSystems =
      if systems == null
      then unique (map (descriptor: descriptor.config.system) (attrValues normalizedHosts))
      else systems;
    # Resolve dependency precedence once for constructors, module discovery,
    # and the context exposed to consumer modules.
    composedInputs =
      (nixi.inputs or {})
      // inputs
      // {
        inherit nixpkgs nixpkgs-darwin nixpkgs-unstable darwin home-manager;
      };
    selfWithInputs = self // {inputs = composedInputs;};
    heyWithInputs = hey // {inputs = composedInputs;};
  in
    compose {
      spec = removeAttrs hostFlake [
        "inputs"
        "self"
        "nixi"
        "hey"
        "nixpkgs"
        "nixpkgs-darwin"
        "nixpkgs-unstable"
        "darwin"
        "home-manager"
      ];
      inputs = composedInputs;
      hosts = normalizedHosts;
      systems = hostSystems;
      # Exported overlay catalogs are available choices, never implicit policy.
      inherit nixpkgs nixpkgs-darwin nixpkgs-unstable darwin home-manager apps checks devShells modules overlays packages hostModules nixpkgsConfig;
      self = selfWithInputs;
      hey = heyWithInputs;
      checkArgs = {hey = heyWithInputs;};
    };
}
