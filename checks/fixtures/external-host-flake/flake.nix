{
  description = "External nixi host flake fixture";

  inputs = {
    nixi.url = "path:../../..";
    site.url = "path:./site-flake";
  };

  outputs = inputs @ {
    nixi,
    ...
  }:
    nixi.lib.mkHostFlake {
      inherit inputs;

      hosts.external-fixture = {
        system = "aarch64-linux";
        module = ./host-module.nix;
      };

      systems = ["aarch64-linux"];
    };
}
