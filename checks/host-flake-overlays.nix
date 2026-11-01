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

    hosts.overlay-host = {
      system = "aarch64-linux";
      module = ./fixtures/host-flake-overlays/host-module.nix;
    };

    systems = ["aarch64-linux"];

    overlays.fixture = final: prev: {
      nixiOverlayMarker = "overlay-applied";
      nixiOverlayPackage = prev.writeText "nixi-overlay-package" "overlay-applied";
    };

    packages.probe = {nixiOverlayPackage, ...}: nixiOverlayPackage;
  };

  host = outputs.nixosConfigurations.overlay-host;
  actual = {
    hostNames = builtins.attrNames outputs.nixosConfigurations;
    overlayMarker = host.config.environment.variables.NIXI_OVERLAY_MARKER;
    packageName = outputs.packages.aarch64-linux.probe.name;
  };

  expected = {
    hostNames = ["overlay-host"];
    overlayMarker = "overlay-applied";
    packageName = "nixi-overlay-package";
  };
in
  assert actual == expected;
  runCommand "host-flake-overlays-check" {
    checked = builtins.toJSON actual;
  } ''
    touch "$out"
  ''
