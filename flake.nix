{
  description = "nixi reusable Nix configuration framework";

  inputs = {
    # Core dependencies
    nixpkgs.url = "nixpkgs/nixos-26.05";
    nixpkgs-unstable.url = "nixpkgs/nixos-unstable";
    nixpkgs-darwin.url = "github:nixos/nixpkgs/nixpkgs-26.05-darwin";
    home-manager.url = "github:nix-community/home-manager/release-26.05";
    home-manager.inputs.nixpkgs.follows = "nixpkgs-unstable";
    darwin.url = "github:LnL7/nix-darwin/nix-darwin-26.05";
    darwin.inputs.nixpkgs.follows = "nixpkgs-darwin";
    alejandra.url = "github:kamadorueda/alejandra/3.0.0";
    alejandra.inputs.nixpkgs.follows = "nixpkgs-unstable";
    doom-emacs = {
      url = "github:marienz/nix-doom-emacs-unstraightened";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };

    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs-unstable";
  };

  outputs = inputs @ {
    self,
    nixpkgs,
    nixpkgs-darwin,
    darwin,
    home-manager,
    ...
  }: let
    args = {
      inherit self;
      inherit darwin;
      inherit home-manager;
      inherit (nixpkgs) lib;
      pkgs = import nixpkgs {};
      pkgs-darwin = import nixpkgs-darwin {};
    };
    lib = import ./lib args;
    checks = lib.mapModules ./checks import;
    devShells = {
      default = import ./devshell.nix;
    };
    overlays.security = import ./overlays/security.nix;
    packages =
      (lib.mapModules ./packages import)
      // {
        default = import ./packages/hey.nix;
      };
    flake = lib.mkFlake inputs {
      # Build ordinary outputs from upstream pins; only export the overlay.
      inherit checks devShells lib packages;
      systems = ["aarch64-darwin" "aarch64-linux" "x86_64-linux"];

      modules.default = import ./.;

      checkDefs = checks;
      devShellDefs = devShells;
      overlayDefs = overlays;
      packageDefs = packages;
    };
  in
    flake
    // {
      inherit overlays;
      nixosModules = flake.nixosModules // {disko = import ./modules/optional/disko.nix;};
      darwinModules = flake.darwinModules // {sops-darwin = import ./modules/optional/sops-darwin.nix;};
    };
}
