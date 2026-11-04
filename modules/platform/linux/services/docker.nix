{
  hey,
  lib,
  config,
  pkgs,
  ...
}: let
  inherit (lib) mkDefault mkIf;
  inherit (hey.lib) mkBoolOpt';

  cfg = config.modules.services.docker;
  native = config.virtualisation.docker;
in {
  options.modules.services.docker = {
    enable = mkBoolOpt' false "Whether to enable Docker and install Docker client tools.";
    grantRootAccess = mkBoolOpt' false "Grant the selected user root-equivalent Docker socket access.";
    rootless = mkBoolOpt' false "Run a per-user rootless Docker daemon instead of the root daemon.";
  };

  config = mkIf cfg.enable {
    user.packages = [
      pkgs.docker
      pkgs.docker-compose
    ];

    home-manager.users.${config.user.name}.home.sessionVariables = {
      DOCKER_CONFIG = "${config.home.configDir}/docker";
      MACHINE_STORAGE_PATH = "${config.home.dataDir}/docker/machine";
    };

    assertions = [
      {
        assertion = !(native.rootless.enable && cfg.grantRootAccess);
        message = "Choose rootless Docker or explicit root-equivalent access, not both.";
      }
    ];
    user.extraGroups = lib.optional (cfg.grantRootAccess && native.enable) "docker";

    modules.shell.zsh.rcFiles = ["${hey.assetsDir}/docker/aliases.zsh"];

    virtualisation = {
      docker = {
        enable = mkDefault (!cfg.rootless);
        rootless = {
          enable = mkDefault cfg.rootless;
          setSocketVariable = mkDefault native.rootless.enable;
        };
        # Installing Docker must not implicitly authorize scheduled deletion.
        # Consumers opt in through the native autoPrune options.
        autoPrune.enable = mkDefault false;
        enableOnBoot = mkDefault false;
      };
    };
  };
}
