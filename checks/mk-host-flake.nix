{
  nixi,
  runCommand,
  ...
}: let
  framework = nixi // {
    apps = {};
    checks = {};
  };
  siteFlake = import ./fixtures/mk-host-flake/site-flake/flake.nix;
  siteOutputs =
    siteFlake.outputs {
      self.outPath = ./fixtures/mk-host-flake/site-flake;
    };

  outputs = nixi.lib.mkHostFlake {
    inputs =
      nixi.inputs
      // {
        self = framework;
        nixi = framework;
        site = siteOutputs;
      };

    hosts.fixture = {
      system = "aarch64-linux";
      module = ./fixtures/mk-host-flake/host-module.nix;
    };
    hosts.path-fixture = ./fixtures/mk-host-flake/path-host.nix;
    hosts.path-module-fixture = ./fixtures/mk-host-flake/path-module-host.nix;

    systems = ["aarch64-linux"];
  };

  fixture = outputs.nixosConfigurations.fixture;
  pathFixture = outputs.nixosConfigurations.path-fixture;
  pathModuleFixture = outputs.nixosConfigurations.path-module-fixture;
  actual = {
    hostNames = builtins.attrNames outputs.nixosConfigurations;
    hostMarker = fixture.config.environment.variables.NIXI_FIXTURE_HOST;
    pathHostMarker = pathFixture.config.environment.variables.NIXI_FIXTURE_PATH_HOST;
    pathModuleHostMarker = pathModuleFixture.config.environment.variables.NIXI_FIXTURE_PATH_MODULE_HOST;
    siteMarker = fixture.config.environment.variables.NIXI_FIXTURE_SITE;
  };
  expected = {
    hostNames = ["fixture" "path-fixture" "path-module-fixture"];
    hostMarker = "1";
    pathHostMarker = "1";
    pathModuleHostMarker = "1";
    siteMarker = "1";
  };
in
  assert actual == expected;
  runCommand "mk-host-flake-check" {
    checked = builtins.toJSON actual;
  } ''
    touch "$out"
  ''
