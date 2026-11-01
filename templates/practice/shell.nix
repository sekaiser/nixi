{pkgs ? import <nixpkgs> {}}:
with pkgs;
  mkShell {
    packages = [
      bacon
      cargo
      cargo-nextest
      clippy
      go
      google-java-format
      gotestsum
      hyperfine
      maven
      openjdk25
      python3
      rust-analyzer
      rustc
      rustfmt
      watchexec
    ];
  }
