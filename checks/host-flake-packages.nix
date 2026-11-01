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

    hosts.package-host = {
      system = "aarch64-linux";
      module = ./fixtures/host-flake-packages/host-module.nix;
    };

    systems = ["aarch64-linux"];

    packages.marker = {writeText, ...}: writeText "nixi-package-marker" "package-marker";
  };

  host = outputs.nixosConfigurations.package-host;
  actual = {
    hostNames = builtins.attrNames outputs.nixosConfigurations;
    hostPackageMarker = host.config.environment.variables.NIXI_PACKAGE_MARKER;
    packageName = outputs.packages.aarch64-linux.marker.name;
  };

  expected = {
    hostNames = ["package-host"];
    hostPackageMarker = "nixi-package-marker";
    packageName = "nixi-package-marker";
  };
in
  assert actual == expected;
  runCommand "host-flake-packages-check" {
    checked = builtins.toJSON actual;
  } ''
    touch "$out"
  ''
