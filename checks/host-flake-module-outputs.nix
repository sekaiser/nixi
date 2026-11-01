{
  nixi,
  runCommand,
  ...
}: let
  framework = nixi // {
    apps = {};
    checks = {};
  };

  providerOutputs = nixi.lib.mkHostFlake {
    inputs =
      nixi.inputs
      // {
        self = framework;
        nixi = framework;
      };

    hosts.provider = {
      system = "aarch64-linux";
      module = ./fixtures/host-flake-module-outputs/provider-host.nix;
    };

    modules.reusable = import ./fixtures/host-flake-module-outputs/reusable-module.nix;

    systems = ["aarch64-linux"];
  };

  consumerOutputs = nixi.lib.mkHostFlake {
    inputs =
      nixi.inputs
      // {
        self = framework;
        nixi = framework;
        provider = providerOutputs;
      };

    hosts.consumer = {
      system = "aarch64-linux";
      module = ./fixtures/host-flake-module-outputs/consumer-host.nix;
    };

    systems = ["aarch64-linux"];
  };

  provider = providerOutputs.nixosConfigurations.provider;
  consumer = consumerOutputs.nixosConfigurations.consumer;
  actual = {
    providerHosts = builtins.attrNames providerOutputs.nixosConfigurations;
    providerDarwinModules = builtins.attrNames providerOutputs.darwinModules;
    providerNixosModules = builtins.attrNames providerOutputs.nixosModules;
    providerMarker = provider.config.environment.variables.NIXI_MODULE_OUTPUTS_PROVIDER;
    consumerMarker = consumer.config.environment.variables.NIXI_MODULE_OUTPUTS_CONSUMER;
    reusableMarker = consumer.config.environment.variables.NIXI_MODULE_OUTPUTS_REUSABLE;
  };

  expected = {
    providerHosts = ["provider"];
    providerDarwinModules = ["reusable"];
    providerNixosModules = ["reusable"];
    providerMarker = "1";
    consumerMarker = "1";
    reusableMarker = "1";
  };
in
  assert actual == expected;
  runCommand "host-flake-module-outputs-check" {
    checked = builtins.toJSON actual;
  } ''
    touch "$out"
  ''
