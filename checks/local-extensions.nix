{
  nixi,
  runCommand,
  ...
}: let
  framework = nixi // {
    apps = {};
    checks = {};
  };

  outputs = nixi.lib.mkHostFlake {
    inputs =
      nixi.inputs
      // {
        self = framework;
        nixi = framework;
      };

    hosts.laptop = import ./fixtures/local-extensions/hosts/laptop.nix;

    systems = ["aarch64-linux"];
  };

  host = outputs.nixosConfigurations.laptop;
  actual = {
    hostNames = builtins.attrNames outputs.nixosConfigurations;
    hostMarker = host.config.environment.variables.NIXI_LOCAL_HOST;
    moduleMarker = host.config.environment.variables.NIXI_LOCAL_MODULE;
    profileMarker = host.config.environment.variables.NIXI_LOCAL_PROFILE;
  };

  expected = {
    hostNames = ["laptop"];
    hostMarker = "1";
    moduleMarker = "1";
    profileMarker = "1";
  };
in
  assert actual == expected;
  runCommand "local-extensions-check" {
    checked = builtins.toJSON actual;
  } ''
    touch "$out"
  ''
