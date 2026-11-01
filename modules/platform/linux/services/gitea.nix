{
  hey,
  config,
  lib,
  pkgs,
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
  };

  config = mkIf cfg.enable {
    # Compatibility defaults, not deployment requirements. Keep existing state
    # locations and security settings stable while native consumer options win.
    # New deployments can use services.gitea directly without this adapter.
    services.gitea = lib.mapAttrsRecursive (_: value: lib.mkDefault value) {
      enable = true;
      user = "gitea";
      group = "gitea";
      stateDir = "/data/apps/gitea";
      appName = cfg.appName;
      lfs.enable = true;
      dump = {
        enable = false;
        interval = "hourly";
        file = "gitea-dump";
        type = "tar.zst";
      };
      settings = {
        server = {
          PROTOCOL = "http";
          DOMAIN = cfg.domain;
          DISABLE_ROUTER_LOG = true;
          DISABLE_SSH = true;
        };
        database.LOG_SQL = false;
        service.ENABLE_BASIC_AUTHENTICATION = true;
        log.LEVEL = cfg.logLevel;
        security = {
          LOGIN_REMEMBER_DAYS = 31;
          PASSWORD_HASH_ALGO = "scrypt";
          MIN_PASSWORD_LENGTH = 10;
        };

        mailer = {
          ENABLED = true;
          MAILER_TYPE = "sendmail";
          FROM = "do-not-reply@${cfg.domain}";
          SENDMAIL_PATH = "${pkgs.system-sendmail}/bin/sendmail";
        };
        other = {
          SHOW_FOOTER_VERSION = false;
        };
      };
      database = {
        type = "sqlite3";
        createDatabase = true;
      };
    };
  };
}
