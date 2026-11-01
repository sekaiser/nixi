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

    hosts.devshell-host = {
      system = "aarch64-linux";
      module = ./fixtures/host-flake-devshells/host-module.nix;
    };

    systems = ["aarch64-linux"];

    devShells.marker = {writeText, ...}: writeText "nixi-devshell-marker" "devshell-marker";
  };

  host = outputs.nixosConfigurations.devshell-host;
  actual = {
    hostNames = builtins.attrNames outputs.nixosConfigurations;
    hostDevShellMarker = host.config.environment.variables.NIXI_DEVSHELL_MARKER;
    devShellName = outputs.devShells.aarch64-linux.marker.name;
  };

  expected = {
    hostNames = ["devshell-host"];
    hostDevShellMarker = "nixi-devshell-marker";
    devShellName = "nixi-devshell-marker";
  };
in
  assert actual == expected;
  runCommand "host-flake-devshells-check" {
    checked = builtins.toJSON actual;
  } ''
    touch "$out"
  ''
