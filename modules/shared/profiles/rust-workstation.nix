{
  config,
  hey,
  lib,
  pkgs,
  ...
}: {
  options.modules.profiles.rust-workstation.enable = lib.mkEnableOption "Rust workstation tools and shell preferences";

  config = lib.mkIf config.modules.profiles.rust-workstation.enable (lib.mkMerge [
    {modules.dev.rust.enable = lib.mkDefault true;}
    (lib.mkIf config.modules.dev.rust.enable {
      modules.shell.zsh.rcFiles = lib.mkIf config.modules.shell.zsh.enable ["${hey.assetsDir}/dev/rust/aliases.zsh"];

      user.packages = [
        pkgs.unstable.rustfmt
        pkgs.unstable.clippy
        pkgs.unstable.rust-analyzer

        pkgs.unstable.bacon
        pkgs.unstable.cargo-audit
        pkgs.unstable.cargo-deny
        pkgs.unstable.cargo-edit
        pkgs.unstable.cargo-flamegraph
        pkgs.unstable.cargo-insta
        pkgs.unstable.cargo-llvm-cov
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
