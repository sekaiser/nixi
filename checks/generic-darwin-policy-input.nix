{
  nixi,
  runCommand,
  ...
}: let
  framework = nixi // {
    apps = {};
    checks = {};
  };
  policyFlake = import ./fixtures/generic-darwin-policy-input/policy-flake/flake.nix;
  policyOutputs =
    policyFlake.outputs {
      self.outPath = ./fixtures/generic-darwin-policy-input/policy-flake;
    };

  outputs = nixi.lib.mkHostFlake {
    inputs =
      nixi.inputs
      // {
        self = framework;
        nixi = framework;
        policy = policyOutputs;
      };

    hosts.generic-darwin-policy = {
      system = "aarch64-darwin";
      module = ./fixtures/generic-darwin-policy-input/host-module.nix;
    };

    systems = ["aarch64-darwin"];
  };

  host = outputs.darwinConfigurations.generic-darwin-policy;
  actual = {
    darwinHostNames = builtins.attrNames outputs.darwinConfigurations;
    nixosHostNames = builtins.attrNames outputs.nixosConfigurations;
    hostMarker = host.config.environment.variables.NIXI_GENERIC_DARWIN_POLICY_HOST;
    inputMarker = host.config.environment.variables.NIXI_GENERIC_DARWIN_POLICY_INPUT;
    moduleSetMarker = host.config.environment.variables.NIXI_GENERIC_DARWIN_POLICY_MODULE_SET;
  };

  expected = {
    darwinHostNames = ["generic-darwin-policy"];
    nixosHostNames = [];
    hostMarker = "1";
    inputMarker = "1";
    moduleSetMarker = "1";
  };
in
  assert actual == expected;
  runCommand "generic-darwin-policy-input-check" {
    checked = builtins.toJSON actual;
  } ''
    touch "$out"
  ''
