{
  config,
  hey,
  lib,
  pkgs,
  ...
}: let
  rustPkgs =
    if config.modules.dev.rust.packageSet == "stable"
    then pkgs
    else pkgs.unstable;
in {
  options.modules.profiles.rust-workstation.enable = lib.mkEnableOption "Rust workstation tools and shell preferences";

  config = lib.mkIf config.modules.profiles.rust-workstation.enable (lib.mkMerge [
    {modules.dev.rust.enable = lib.mkDefault true;}
    (lib.mkIf config.modules.dev.rust.enable {
      modules.shell.zsh.rcFiles = lib.mkIf config.modules.shell.zsh.enable ["${hey.assetsDir}/dev/rust/aliases.zsh"];

      user.packages = [
        rustPkgs.rustfmt
        rustPkgs.clippy
        rustPkgs.rust-analyzer

        pkgs.unstable.bacon
        pkgs.unstable.cargo-audit
        pkgs.unstable.cargo-deny
        pkgs.unstable.cargo-edit
        pkgs.unstable.cargo-flamegraph
        pkgs.unstable.cargo-insta
        rustPkgs.cargo-llvm-cov
        pkgs.unstable.cargo-mutants
        pkgs.unstable.cargo-nextest
        pkgs.unstable.cargo-udeps
        pkgs.unstable.cargo-watch

        pkgs.unstable.hyperfine
        pkgs.unstable.samply
        pkgs.unstable.sccache
        pkgs.unstable.taplo
        pkgs.unstable.typos
      ];
    })
  ]);
}
