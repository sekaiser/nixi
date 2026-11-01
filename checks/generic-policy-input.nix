{
  nixi,
  runCommand,
  ...
}: let
  framework = nixi // {
    apps = {};
    checks = {};
  };
  policyFlake = import ./fixtures/generic-policy-input/policy-flake/flake.nix;
  policyOutputs =
    policyFlake.outputs {
      self.outPath = ./fixtures/generic-policy-input/policy-flake;
    };

  outputs = nixi.lib.mkHostFlake {
    inputs =
      nixi.inputs
      // {
        self = framework;
        nixi = framework;
        policy = policyOutputs;
      };

    hosts.generic-policy = {
      system = "aarch64-linux";
      module = ./fixtures/generic-policy-input/host-module.nix;
    };

    systems = ["aarch64-linux"];
  };

  host = outputs.nixosConfigurations.generic-policy;
  actual = {
    hostNames = builtins.attrNames outputs.nixosConfigurations;
    hostMarker = host.config.environment.variables.NIXI_GENERIC_POLICY_HOST;
    inputMarker = host.config.environment.variables.NIXI_GENERIC_POLICY_INPUT;
    moduleSetMarker = host.config.environment.variables.NIXI_GENERIC_POLICY_MODULE_SET;
  };

  expected = {
    hostNames = ["generic-policy"];
    hostMarker = "1";
    inputMarker = "1";
    moduleSetMarker = "1";
  };
in
  assert actual == expected;
  runCommand "generic-policy-input-check" {
    checked = builtins.toJSON actual;
  } ''
    touch "$out"
  ''
