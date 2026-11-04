{
  root,
  system,
  flake ? builtins.getFlake ("path:" + root),
}: let
  policy = builtins.fromJSON (builtins.readFile ./dependency-coverage.json);
  lib = flake.inputs.nixpkgs.lib;
  darwin = lib.hasSuffix "-darwin" system;
  outputs = flake.lib.mkHostFlake {
    inputs = {
      self.outPath = ../checks/fixtures/cli-host;
      nixi = flake;
    };
    # Framework check arguments omit instantiated package outputs. Reconstruct
    # their ordinary public catalog for those checks, using the same recipes.
    packages = lib.mapAttrs (name: _: import (../packages + "/${name}.nix")) policy.frameworkPackages;
    hosts.inventory = {
      inherit system;
      module = _: {
        config = {
          user = {
            name = "inventory";
            home = "/fixture/inventory";
          };
          home.stateVersion = "26.05";
          system.stateVersion =
            if darwin
            then 6
            else "26.05";
          modules.services = lib.optionalAttrs (!darwin) {
            caddy.enable = true;
            docker.enable = true;
            gitea = {
              enable = true;
              domain = "git.example.invalid";
              deploymentPolicy = "native";
            };
            k3s-server.enable = true;
            tailscale.enable = true;
          };
        };
      };
    };
  };
  host =
    if darwin
    then outputs.darwinConfigurations.inventory
    else outputs.nixosConfigurations.inventory;
  cfg = host.config;
  services = lib.optionalAttrs (!darwin) {
    caddy = cfg.services.caddy.package;
    docker = cfg.virtualisation.docker.package;
    gitea = cfg.services.gitea.package;
    k3s = cfg.services.k3s.package;
    tailscale = cfg.services.tailscale.package;
  };
  describe = kind: package: {
    inherit kind;
    name = lib.getName package;
    version = package.version or null;
    drvPath = package.drvPath;
  };
  packages = lib.filterAttrs (_: disposition: disposition == "scan") policy.frameworkPackages;
  catalog =
    if flake ? packages
    then flake.packages.${system}
    else outputs.packages.${system};
in
  assert lib.elem system policy.systems; {
    inherit system;
    targets =
      lib.mapAttrs' (name: _: lib.nameValuePair "framework/${name}" (describe "framework" catalog.${name})) packages
      // lib.mapAttrs' (name: package: lib.nameValuePair "service/${name}" (describe "service" package)) services
      // {"editor/emacs-base" = describe "editor" cfg.modules.editors.emacs.package;};
    addonPins = import ../lib/internal/addon-pins.nix;
  }
