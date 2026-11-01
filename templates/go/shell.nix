{pkgs ? import <nixpkgs> {}}:
with pkgs;
  mkShell {
    packages = [
      air
      go
      golangci-lint
      gopls
      gotestsum
      govulncheck
    ];
  }
