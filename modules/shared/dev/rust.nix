{
  hey,
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkIf;
  inherit (hey.lib) mkBoolOpt;

  cfg = config.modules.dev.rust;
  rustPkgs =
    if cfg.packageSet == "stable"
    then pkgs
    else pkgs.unstable;
in {
  options.modules.dev.rust = {
    enable = mkBoolOpt false;
    packageSet = lib.mkOption {
      type = lib.types.enum ["stable" "unstable"];
      default = "unstable";
      description = "Nixpkgs source for the Rust toolchain and its coupled workstation tools";
    };
  };

  config = mkIf cfg.enable {
    user.packages = [
      rustPkgs.rustc
      rustPkgs.cargo
    ];
  };
}
