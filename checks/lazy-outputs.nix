{
  lib,
  runCommand,
  ...
}: let
  flake = import ../lib/flake {
    inherit lib;
    nixpkgsLib.mkPkgs = _: {callPackage = fn: args: fn args;};
  };
  outputs = flake.mkFlakeOutputs {
    flake = {};
    modules = {};
    darwinConfigurations.laptop = "host remains accessible";
    nixosConfigurations = {};
    perSystem = flake.mkPerSystemOutputs {
      systems = ["aarch64-darwin" "x86_64-linux"];
      nixpkgs = null;
      overlays = {};
      apps = {};
      devShells = {};
      packages = {
        working = _: "working sibling";
        broken = _: throw "Deliberately failing unrelated package";
        linuxOnly = {
          systems = ["x86_64-linux"];
          package = _: "linux only";
        };
      };
      checks.broken = _: throw "Deliberately failing unrelated check";
    };
  };
in
  assert outputs.darwinConfigurations.laptop == "host remains accessible";
  assert builtins.attrNames outputs.checks == ["aarch64-darwin" "x86_64-linux"];
  assert !(builtins.tryEval outputs.checks.aarch64-darwin.broken).success;
  assert outputs.packages.aarch64-darwin.working == "working sibling";
  assert !(outputs.packages.aarch64-darwin ? linuxOnly);
  assert outputs.packages.x86_64-linux.linuxOnly == "linux only";
    runCommand "lazy-outputs-check" {} ''touch "$out"''
