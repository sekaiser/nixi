{
  hey,
  config,
  lib,
  ...
}: let
  inherit (lib) mkIf mkOption types;
  inherit (hey.lib) mkBoolOpt';

  cfg = config.modules.services.gitea;
in {
  options.modules.services.gitea = {
    enable = mkBoolOpt' false "Whether to enable Gitea.";
    domain = mkOption {
      type = types.str;
      description = "Public domain name for the Gitea service.";
    };
    appName = mkOption {
      type = types.str;
      default = "Gitea";
      description = "Display name for the Gitea service.";
    };
    logLevel = mkOption {
      type = types.str;
      default = "Info";
      description = "Gitea log level.";
    };
    deploymentPolicy = mkOption {
      type = types.nullOr (types.enum ["native"]);
      default = null;
      description = "Select native Gitea deployment defaults explicitly after reviewing storage, database, mail and login behavior. Alternatively enable the gitea-compatibility preset to retain the former adapter policy. No data migration is performed.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = !config.services.gitea.enable || ((cfg.deploymentPolicy == "native") != (config.modules.profiles.gitea-compatibility.enable or false));
        message = ''Select exactly one Gitea deployment policy: enable modules.profiles.gitea-compatibility to retain existing defaults, or set modules.services.gitea.deploymentPolicy = "native" after reviewing storage, database, mail and login settings.'';
      }
    ];
    # Identity wiring only. Storage and operational policy are native settings
    # or the explicitly selected compatibility preset, never a silent migration.
    services.gitea = lib.mapAttrsRecursive (_: value: lib.mkDefault value) {
      enable = true;
      appName = cfg.appName;
      settings = {
        server.DOMAIN = cfg.domain;
        log.LEVEL = cfg.logLevel;
      };
    };
  };
}
