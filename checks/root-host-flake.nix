{
  nixi,
  runCommand,
  ...
}: let
  outputs = nixi.lib.mkHostFlake {
    inputs =
      nixi.inputs
      // {
        self = nixi;
        nixi = nixi;
      };

    hosts.root-fixture = {
      system = "aarch64-linux";
      module = ./fixtures/root-host-flake/host-module.nix;
    };

    packages.probe = {runCommand, ...}:
      runCommand "root-host-flake-probe" {} ''
        touch "$out"
      '';
  };

  actual = {
    nixosHosts = builtins.attrNames outputs.nixosConfigurations;
    darwinHosts = builtins.attrNames outputs.darwinConfigurations;
    packageSystems = builtins.attrNames outputs.packages;
    hostMarker = outputs.nixosConfigurations.root-fixture.config.environment.variables.NIXI_ROOT_HOST;
    leaksInputsOutput = outputs ? inputs;
    leaksHostsOutput = outputs ? hosts;
    leaksModulesOutput = outputs ? modules;
  };

  expected = {
    nixosHosts = ["root-fixture"];
    darwinHosts = [];
    packageSystems = ["aarch64-linux"];
    hostMarker = "1";
    leaksInputsOutput = false;
    leaksHostsOutput = false;
    leaksModulesOutput = false;
  };
in
  assert actual == expected;
  runCommand "root-host-flake-check" {
    checked = builtins.toJSON actual;
  } ''
    touch "$out"
  ''
