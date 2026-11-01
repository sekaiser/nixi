{
  nixi,
  lib,
  runCommand,
  ...
}: let
  dependencies = ["nixpkgs" "nixpkgs-darwin" "nixpkgs-unstable" "darwin" "home-manager"];
  marked = marker:
    lib.genAttrs dependencies (name:
      nixi.inputs.${name} // {reviewMarker = marker;});
  homeManager = marker:
    nixi.inputs.home-manager
    // {
      reviewMarker = marker;
      nixosModules =
        lib.mapAttrs (_: module: {
          imports = [module];
          environment.variables.NIXI_HM_OVERRIDE = marker;
        })
        nixi.inputs.home-manager.nixosModules;
      darwinModules =
        lib.mapAttrs (_: module: {
          imports = [module];
          environment.variables.NIXI_HM_OVERRIDE = marker;
        })
        nixi.inputs.home-manager.darwinModules;
    };
  selected = marker: (marked marker) // {home-manager = homeManager marker;};
  spec = {
    inputs =
      {
        self.outPath = ./fixtures/cli-host;
        inherit nixi;
      }
      // selected "input";
    hosts = lib.genAttrs ["linux" "darwin"] (platform: {
      system =
        if platform == "linux"
        then "x86_64-linux"
        else "aarch64-darwin";
      module = {hey, ...}: {
        config = {
          user = {
            name = "alice";
            home = "/fixture/alice";
          };
          home.stateVersion = "26.05";
          system.stateVersion =
            if platform == "linux"
            then "26.05"
            else 6;
          environment.variables.NIXI_INPUT_CONTEXT =
            lib.concatMapStringsSep "," (name: hey.inputs.${name}.reviewMarker) dependencies;
        };
      };
    });
  };
  direct = nixi.lib.mkHostFlake (spec // selected "direct");
  viaInputs = nixi.lib.mkHostFlake spec;
  verifies = outputs: marker:
    lib.all (host:
      host.config.environment.variables.NIXI_HM_OVERRIDE
      == marker
      && host.config.environment.variables.NIXI_INPUT_CONTEXT
      == lib.concatMapStringsSep "," (_: marker) dependencies)
    [outputs.nixosConfigurations.linux outputs.darwinConfigurations.darwin];
in
  assert verifies direct "direct";
  assert verifies viaInputs "input";
  assert !lib.any (name: builtins.hasAttr name direct) (dependencies ++ ["inputs" "nixi" "self" "hey"]);
    runCommand "dependency-overrides-check" {} ''touch "$out"''
