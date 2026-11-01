# Colima owns runtime state and Docker context selection; Nix supplies the tools.
{
  hey,
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) escapeShellArg mkIf optionalAttrs;
  inherit (lib.types) nullOr str;
  inherit (hey.lib) mkBoolOpt mkOpt';

  cfg = config.modules.services.docker;
in {
  options.modules.services.docker = {
    enable = mkBoolOpt false;
    colimaHome = mkOpt' (nullOr str) null "Optional absolute Colima state directory. Null keeps native discovery, including existing ~/.colima state. No VM data is moved.";
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.colimaHome == null || (lib.hasPrefix "/" cfg.colimaHome && cfg.colimaHome != "/");
        message = "modules.services.docker.colimaHome must be an absolute, non-root directory.";
      }
    ];

    home-manager.users.${config.user.name}.home = {
      sessionVariables =
        {
          DOCKER_CONFIG = "${config.home.configDir}/docker";
          TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE = "/var/run/docker.sock";
        }
        // optionalAttrs (cfg.colimaHome != null) {COLIMA_HOME = cfg.colimaHome;};

      # Colima only honors COLIMA_HOME when the directory exists. Do not migrate
      # existing state or select a Docker context during system activation.
      activation = optionalAttrs (cfg.colimaHome != null) {
        createColimaHome = config.home-manager.users.${config.user.name}.lib.dag.entryAfter ["writeBoundary"] ''
          (umask 077; $DRY_RUN_CMD ${pkgs.coreutils}/bin/mkdir -p -- ${escapeShellArg cfg.colimaHome})
        '';
      };
    };

    user.packages = [
      pkgs.colima
      pkgs.docker
      pkgs.docker-compose
      pkgs.docker-buildx
    ];

    home.configFile = {
      "docker" = {
        source = "${hey.assetsDir}/docker";
        recursive = true;
      };

      "docker/cli-plugins/docker-compose" = {
        source = "${pkgs.docker-compose}/bin/docker-compose";
      };

      "docker/cli-plugins/docker-buildx" = {
        source = "${pkgs.docker-buildx}/bin/docker-buildx";
      };
    };
  };
}
