# modules/profiles/default.nix
{
  hey,
  lib,
  config,
  ...
}: let
  inherit (lib.types) listOf str;
  inherit (hey.lib) mkOpt;
in {
  imports = [
    ./workstation.nix
    ./zed-workstation.nix
    ./alacritty-workstation.nix
    ./doom-workstation.nix
    ./zsh-workstation.nix
    ./tmux-workstation.nix
    ./home-workstation.nix
    ./atuin-workstation.nix
    ./rust-workstation.nix
    ./go-workstation.nix
    ./java-workstation.nix
    ./omp-workstation.nix
    ./vim-workstation.nix
  ];
  options.modules.profiles = {
    user = mkOpt str "";
    role = mkOpt str "";
    platform = mkOpt str "";
    hardware = mkOpt (listOf str) [];
    networks = mkOpt (listOf str) [];
  };

  # Runtime metadata is an explicit contract, not a dump of profile options.
  # Feature modules may publish the small subset their CLI consumers need.
  config.hey.info.profiles = {
    inherit (config.modules.profiles) user role platform hardware networks;
  };
}
