{
  config,
  lib,
  pkgs,
  ...
}: {
  options.modules.profiles.gitea-compatibility.enable = lib.mkEnableOption "the former Gitea adapter's deployment defaults";
  config = lib.mkIf config.modules.profiles.gitea-compatibility.enable (lib.mkMerge [
    {modules.services.gitea.enable = lib.mkDefault true;}
    (lib.mkIf (config.modules.services.gitea.enable && config.services.gitea.enable) {
      # Preserve existing data and operational choices. Ordinary native settings
      # override every default; this preset never moves or converts stored data.
      services.gitea = lib.mapAttrsRecursive (_: value: lib.mkDefault value) {
        user = "gitea";
        group = "gitea";
        stateDir = "/data/apps/gitea";
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
            DISABLE_ROUTER_LOG = true;
            DISABLE_SSH = true;
          };
          database.LOG_SQL = false;
          service.ENABLE_BASIC_AUTHENTICATION = true;
          security = {
            LOGIN_REMEMBER_DAYS = 31;
            PASSWORD_HASH_ALGO = "scrypt";
            MIN_PASSWORD_LENGTH = 10;
          };
          mailer = {
            ENABLED = true;
            MAILER_TYPE = "sendmail";
            FROM = "do-not-reply@${config.modules.services.gitea.domain}";
            SENDMAIL_PATH = "${pkgs.system-sendmail}/bin/sendmail";
          };
          other.SHOW_FOOTER_VERSION = false;
        };
        database = {
          type = "sqlite3";
          createDatabase = true;
        };
      };
    })
  ]);
}
