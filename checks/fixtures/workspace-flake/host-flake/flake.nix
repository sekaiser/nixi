{
  description = "Workspace host flake fixture";

  inputs = {
    nixi.url = "path:../../../..";
    site.url = "path:../site-flake";
  };

  outputs = inputs:
    inputs.nixi.lib.mkHostFlake {
      inherit inputs;

      hosts.analytics = import ./hosts/analytics.nix;

      systems = ["aarch64-linux"];
    };
}
