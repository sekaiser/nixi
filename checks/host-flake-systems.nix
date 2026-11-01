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

    hosts.linux-only = {
      system = "aarch64-linux";
      module = ./fixtures/host-flake-systems/linux-host.nix;
    };

    systems = ["aarch64-darwin" "aarch64-linux"];

    packages.probe = {runCommand, ...}:
      runCommand "host-flake-systems-probe" {} ''
        touch "$out"
      '';
  };

  actual = {
    nixosHosts = builtins.attrNames outputs.nixosConfigurations;
    darwinHosts = builtins.attrNames outputs.darwinConfigurations;
    packageSystems = builtins.attrNames outputs.packages;
    linuxMarker = outputs.nixosConfigurations.linux-only.config.environment.variables.NIXI_HOST_FLAKE_SYSTEMS;
  };

  expected = {
    nixosHosts = ["linux-only"];
    darwinHosts = [];
    packageSystems = ["aarch64-darwin" "aarch64-linux"];
    linuxMarker = "1";
  };
in
  assert actual == expected;
  runCommand "host-flake-systems-check" {
    checked = builtins.toJSON actual;
  } ''
    touch "$out"
  ''
