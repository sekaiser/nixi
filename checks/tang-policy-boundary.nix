{
  nixi,
  runCommand,
  ...
}: let
  hostModule = withPolicy: _: {
    config = {lib, ...}: {
      user = {
        name = "tang-check";
        home = "/home/tang-check";
      };
      system.stateVersion = "26.05";
      home.stateVersion = "26.05";
      modules.services.tang.enable = true;
      services.tang.ipAddressAllow = lib.mkIf withPolicy ["192.0.2.0/24"];
    };
  };
  outputs = nixi.lib.mkHostFlake {
    inputs = nixi.inputs // {self = nixi;};
    systems = ["aarch64-linux"];
    hosts = {
      configured = {
        system = "aarch64-linux";
        module = hostModule true;
      };
      missing = {
        system = "aarch64-linux";
        module = hostModule false;
      };
    };
  };
  socket = outputs.nixosConfigurations.configured.config.systemd.sockets.tangd.socketConfig;
  actual = {
    allow = socket.IPAddressAllow;
    deny = socket.IPAddressDeny;
    missingPolicyRejected =
      builtins.any
      (assertion:
        assertion.message
        == "modules.services.tang requires an explicit nonempty services.tang.ipAddressAllow."
        && !assertion.assertion)
      outputs.nixosConfigurations.missing.config.assertions;
  };
in
  assert actual
  == {
    allow = ["192.0.2.0/24"];
    deny = "any";
    missingPolicyRejected = true;
  };
    runCommand "tang-policy-boundary-check" {
      checked = builtins.toJSON actual;
    } ''
      touch "$out"
    ''
