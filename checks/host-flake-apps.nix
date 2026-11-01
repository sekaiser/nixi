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

    hosts.app-host = {
      system = "aarch64-linux";
      module = ./fixtures/host-flake-apps/host-module.nix;
    };

    systems = ["aarch64-linux"];

    apps.marker = {
      type = "app";
      program = "/bin/nixi-app-marker";
    };
  };

  host = outputs.nixosConfigurations.app-host;
  actual = {
    hostNames = builtins.attrNames outputs.nixosConfigurations;
    hostAppMarker = host.config.environment.variables.NIXI_APP_MARKER;
    appProgram = outputs.apps.aarch64-linux.marker.program;
  };

  expected = {
    hostNames = ["app-host"];
    hostAppMarker = "/bin/nixi-app-marker";
    appProgram = "/bin/nixi-app-marker";
  };
in
  assert actual == expected;
  runCommand "host-flake-apps-check" {
    checked = builtins.toJSON actual;
  } ''
    touch "$out"
  ''
