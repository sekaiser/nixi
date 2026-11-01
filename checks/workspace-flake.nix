{
  nixi,
  runCommand,
  ...
}: let
  framework = nixi // {
    apps = {};
    checks = {};
  };

  siteFlake = import ./fixtures/workspace-flake/site-flake/flake.nix;
  siteOutputs =
    siteFlake.outputs {
      self.outPath = ./fixtures/workspace-flake/site-flake;
    };

  hostFlake = import ./fixtures/workspace-flake/host-flake/flake.nix;
  hostOutputs =
    hostFlake.outputs {
      self.outPath = ./fixtures/workspace-flake/host-flake;
      nixi = framework;
      site = siteOutputs;
    };
  hostWorkspaceInput =
    hostOutputs
    // {
      checks.aarch64-linux.host = "host-check";
    };

  workspaceFlake = import ./fixtures/workspace-flake/flake.nix;
  workspaceOutputs =
    workspaceFlake.outputs {
      self.outPath = ./fixtures/workspace-flake;
      nixi = framework;
      site = siteOutputs;
      hosts = hostWorkspaceInput;
    };

  host = hostOutputs.nixosConfigurations.analytics;

  actual = {
    hostNames = builtins.attrNames hostOutputs.nixosConfigurations;
    hostMarker = host.config.environment.variables.NIXI_WORKSPACE_HOST;
    siteMarker = host.config.environment.variables.NIXI_WORKSPACE_SITE;
    hostFlakeLeaksInputsOutput = hostOutputs ? inputs;
    workspaceCheckNames = builtins.attrNames workspaceOutputs.checks.aarch64-linux;
    hasWorkspaceApps = workspaceOutputs ? apps;
  };

  expected = {
    hostNames = ["analytics"];
    hostMarker = "1";
    siteMarker = "1";
    hostFlakeLeaksInputsOutput = false;
    workspaceCheckNames = ["host" "site"];
    hasWorkspaceApps = true;
  };
in
  assert actual == expected;
  runCommand "workspace-flake-check" {
    checked = builtins.toJSON actual;
  } ''
    touch "$out"
  ''
