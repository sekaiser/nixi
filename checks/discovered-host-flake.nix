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

    hosts = nixi.lib.mapHosts ./fixtures/discovered-host-flake/hosts;

    packages.probe = {runCommand, ...}:
      runCommand "discovered-host-flake-probe" {} ''
        touch "$out"
      '';
  };

  actual = {
    hostNames = builtins.attrNames outputs.nixosConfigurations;
    darwinHosts = builtins.attrNames outputs.darwinConfigurations;
    packageSystems = builtins.attrNames outputs.packages;
    analyticsMarker = outputs.nixosConfigurations.analytics.config.environment.variables.NIXI_DISCOVERED_ANALYTICS;
    workerMarker = outputs.nixosConfigurations.worker.config.environment.variables.NIXI_DISCOVERED_WORKER;
  };

  expected = {
    hostNames = ["analytics" "worker"];
    darwinHosts = [];
    packageSystems = ["aarch64-linux" "x86_64-linux"];
    analyticsMarker = "1";
    workerMarker = "1";
  };
in
  assert actual == expected;
  runCommand "discovered-host-flake-check" {
    checked = builtins.toJSON actual;
  } ''
    touch "$out"
  ''
