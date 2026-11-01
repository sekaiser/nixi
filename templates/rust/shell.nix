{pkgs ? import <nixpkgs> {}}:
with pkgs;
  mkShell {
    packages = [
      bacon
      cargo-audit
      cargo-deny
      cargo-llvm-cov
      cargo-nextest
      clippy
      rust-analyzer
      rustc
      rustfmt
      taplo
      typos
    ];
  }
