{
  description = "Rust project";

  inputs = {
    nixpkgs.url = "nixpkgs/nixos-unstable";
  };

  outputs = {
    self,
    nixpkgs,
  }: let
    systems = [
      "aarch64-darwin"
      "aarch64-linux"
      "x86_64-linux"
    ];
    forAllSystems = f:
      nixpkgs.lib.genAttrs systems (system:
        f {
          pkgs = import nixpkgs {inherit system;};
        });
  in {
    devShells = forAllSystems ({pkgs}: {
      default = pkgs.mkShell {
        packages = with pkgs; [
          bacon
          cargo-audit
          cargo-deny
          cargo-llvm-cov
          cargo-nextest
          clippy
          process-compose
          rust-analyzer
          rustc
          rustfmt
          taplo
          typos
        ];
      };
    });

    checks = forAllSystems ({pkgs}: {
      format = pkgs.runCommand "rust-project-format-check" {} ''
        cd ${self}
        ${pkgs.rustfmt}/bin/cargo-fmt --check
        ${pkgs.taplo}/bin/taplo fmt --check
        ${pkgs.typos}/bin/typos
        touch $out
      '';
    });
  };
}
