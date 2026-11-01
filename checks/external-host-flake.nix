{
  nixi,
  runCommand,
  ...
}: let
  framework =
    nixi
    // {
      apps = {};
      checks = {};
    };
  fixtureFlake = import ./fixtures/external-host-flake/flake.nix;
  siteFlake = import ./fixtures/external-host-flake/site-flake/flake.nix;
  siteOutputs = siteFlake.outputs {
    self.outPath = ./fixtures/external-host-flake/site-flake;
  };

  outputs = fixtureFlake.outputs {
    self.outPath = ./fixtures/external-host-flake;
    nixi = framework;
    site = siteOutputs;
  };

  fixture = outputs.nixosConfigurations.external-fixture;
  actual = {
    hostNames = builtins.attrNames outputs.nixosConfigurations;
    hostMarker = fixture.config.environment.variables.NIXI_EXTERNAL_HOST;
    siteMarker = fixture.config.environment.variables.NIXI_EXTERNAL_SITE;
    workspaceRoot = fixture.config.environment.variables.NIXI_EXTERNAL_WORKSPACE;
    frameworkRoot = fixture.config.environment.variables.NIXI_EXTERNAL_FRAMEWORK;
    contextHasPath = fixture.config.environment.variables.NIXI_EXTERNAL_CONTEXT_HAS_PATH;
    leaksInputsOutput = outputs ? inputs;
  };
  expected = {
    hostNames = ["external-fixture"];
    hostMarker = "1";
    siteMarker = "1";
    workspaceRoot = toString ./fixtures/external-host-flake;
    frameworkRoot = toString nixi;
    contextHasPath = "0";
    leaksInputsOutput = false;
  };
in
  assert actual == expected;
    runCommand "external-host-flake-check" {
      checked = builtins.toJSON actual;
    } ''
      touch "$out"
    ''
