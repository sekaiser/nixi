{
  nixi,
  lib,
  bash,
  coreutils,
  jq,
  caddy,
  runCommand,
  writeText,
  writeShellScriptBin,
  ...
}: let
  outputs = nixi.lib.mkHostFlake {
    inputs = {
      self.outPath = ./fixtures/cli-host;
      inherit nixi;
    };
    hosts.server = {
      system = "x86_64-linux";
      module = _: {
        config = {
          user = {
            name = "alice";
            home = "/home/alice";
          };
          home.stateVersion = "26.05";
          system.stateVersion = "26.05";
        };
      };
    };
  };
  host = outputs.nixosConfigurations.server;
  extend = module: (host.extendModules {modules = [module];}).config;
  sshDefault = extend {modules.services.ssh.enable = true;};
  sshExplicitDns = extend {
    modules.services.ssh.enable = true;
    services.openssh.settings.UseDns = true;
  };
  secretPath = ''/run/secrets/auth key 100% ' " $(literal)'';
  flags = ["--hostname=two words" ''--login-server=https://example.invalid/?x=1&y=$(literal)'' "--advertise-tags=tag:work"];
  tailModule.modules.services.tailscale = {
    enable = true;
    keyFile = secretPath;
    extraUpFlags = flags;
  };
  tail = extend tailModule;
  manual = extend {modules.services.tailscale.enable = true;};
  native = extend {
    imports = [tailModule];
    services.tailscale = {
      authKeyFile = "/run/native-key";
      port = 41642;
      permitCertUid = "consumer";
    };
  };
  invalid = extend {
    modules.services.tailscale = {
      enable = true;
      keyFile = "relative";
    };
  };
  auto = tail.systemd.services.tailscaled-autoconnect;
  ip = tail.systemd.services.tailscale-fetch-ip;
  plain = extend {
    modules.services.caddy.enable = true;
    services.caddy.virtualHosts."example.invalid".extraConfig = ''respond "OK"'';
  };
  independent = extend {
    modules.services = {
      caddy.enable = true;
      gitea = {
        enable = true;
        domain = "git.example.invalid";
      };
    };
  };
  profileModule = {
    modules.profiles.gitea-tailscale.enable = true;
    modules.services.gitea.domain = "git.example.ts.net";
    services.caddy.virtualHosts."public.example.invalid".extraConfig = ''respond "public"'';
  };
  giteaNative = extend {
    modules.services.gitea = {
      enable = true;
      domain = "git.example.invalid";
    };
    services.gitea = {
      stateDir = "/srv/git";
      user = "forge";
      group = "forge";
      appName = "Consumer Forge";
      lfs.enable = false;
      database = {
        type = "postgres";
        createDatabase = false;
      };
      dump = {
        enable = true;
        interval = "daily";
        file = "consumer-dump";
        type = "tar.gz";
      };
      settings = {
        server = {
          PROTOCOL = "https";
          DOMAIN = "native.example.invalid";
          DISABLE_ROUTER_LOG = false;
          DISABLE_SSH = false;
        };
        database.LOG_SQL = true;
        service.ENABLE_BASIC_AUTHENTICATION = false;
        log.LEVEL = "Warn";
        security = {
          LOGIN_REMEMBER_DAYS = 7;
          PASSWORD_HASH_ALGO = "argon2";
          MIN_PASSWORD_LENGTH = 16;
        };
        mailer = {
          ENABLED = false;
          MAILER_TYPE = "smtp";
          FROM = "forge@example.invalid";
          SENDMAIL_PATH = "/run/current-system/sw/bin/sendmail";
        };
        other.SHOW_FOOTER_VERSION = true;
      };
    };
  };
  giteaAlone = extend {
    modules.services.gitea = {
      enable = true;
      domain = "git.example.invalid";
    };
  };
  giteaDisabled = extend {
    modules.services.gitea = {
      enable = true;
      domain = "git.example.invalid";
    };
    services.gitea.enable = false;
  };
  profile = extend profileModule;
  overridden = extend {
    imports = [profileModule];
    modules.profiles.gitea-tailscale.httpsPort = 443;
    services.gitea.settings.server.HTTP_PORT = 3456;
    services.gitea.settings.server.HTTP_ADDR = "::1";
    services.caddy.user = "proxy";
  };
  server = profile.services.gitea.settings.server;
  key = writeText "tailscale-fixture-key" "fixture-key\n";
  script = writeText "tailscaled-native-authentication" (lib.replaceStrings
    [tail.services.tailscale.authKeyFile] ["${key}"]
    auto.script);
  ipScript = writeText "tailscale-ip-fixture" (lib.replaceStrings
    ["/var/tailscale"] [''"$IP_DIR"'']
    ip.script);
  mockTailscale = writeShellScriptBin "tailscale" ''
    count=0
    if [ -e "$COUNT_FILE" ]; then count="$(cat "$COUNT_FILE")"; fi
    case "$1" in
      status)
        count=$((count + 1)); printf '%s' "$count" > "$COUNT_FILE"
        if [ "$FIXTURE_OFFLINE" = 1 ]; then exit 1; fi
        case "$count" in
          1) printf '{"BackendState":"Starting"}' ;;
          2) printf '{"BackendState":"NeedsLogin"}' ;;
          3) printf '{"BackendState":"Running"}' ;;
          *) echo 'Unexpected authentication polling' >&2; exit 1 ;;
        esac
        ;;
      up) printf '%s\n' "$@" > "$ARGV_FILE" ;;
      ip)
        count=$((count + 1)); printf '%s' "$count" > "$COUNT_FILE"
        case "$count" in
          1) exit 0 ;; # Interface exists, no address yet.
          2) exit 1 ;; # Daemon is temporarily unavailable.
          3) printf '198.51.100.7\n' ;;
          *) exit 1 ;;
        esac
        ;;
      *) exit 1 ;;
    esac
  '';
  mockSleep = writeShellScriptBin "sleep" ''
    # Bound a regressed polling loop instead of hanging the check runner.
    test "$(cat "$COUNT_FILE")" -lt 5
  '';
  mockNotify = writeShellScriptBin "systemd-notify" ''
    test "$1" = --ready
    touch "$READY_FILE"
  '';
  expectedArgs = writeText "tailscale-expected-argv" (lib.concatStringsSep "\n" (["up" "--auth-key" "fixture-key"] ++ flags) + "\n");
  # Adapt evaluated global/site snippets on the native runner, without starting
  # a server, requesting certificates or building foreign-platform packages.
  caddyfile = cfg:
    writeText "service-policy.Caddyfile" ''
      {
        ${cfg.services.caddy.globalConfig}
      }
      ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: vhost: ''
          ${name} {
            ${vhost.extraConfig}
          }
        '')
        cfg.services.caddy.virtualHosts)}
    '';
in
  # Hey's SSH policy probe can certify the default, but still refuses explicit
  # DNS-based Match policies. Never override a consumer's deliberate setting.
  assert !sshDefault.services.openssh.settings.UseDns;
  assert sshExplicitDns.services.openssh.settings.UseDns;
  assert tail.services.tailscale.authKeyFile == "/run/credentials/tailscaled-autoconnect.service/nixi-auth-key";
  assert auto.serviceConfig.LoadCredential == ["nixi-auth-key:${lib.replaceStrings ["%"] ["%%"] secretPath}"];
  assert lib.elem "tailscaled.service" auto.after && lib.elem "tailscaled.service" auto.wants;
  assert !(tail.systemd.services ? tailscale-autoconnect);
  assert auto.serviceConfig.Type == "notify" && auto.serviceConfig.Restart == "on-failure";
  assert auto.unitConfig.StartLimitIntervalSec == 0;
  assert lib.elem "tailscaled-autoconnect.service" ip.after;
  assert ip.serviceConfig.Restart == "on-failure" && ip.serviceConfig.TimeoutStartSec == "2min";
  assert tail.services.tailscale.permitCertUid == null;
  assert manual.services.tailscale.authKeyFile == null && !(manual.systemd.services ? tailscaled-autoconnect);
  assert manual.systemd.services.tailscale-fetch-ip.wantedBy == [];
  assert native.services.tailscale.authKeyFile == "/run/native-key";
  assert !(native.systemd.services.tailscaled-autoconnect.serviceConfig ? LoadCredential);
  assert native.services.tailscale.permitCertUid == "consumer";
  assert lib.elem 41642 native.networking.firewall.allowedUDPPorts && !(lib.elem 41641 native.networking.firewall.allowedUDPPorts);
  # Invalid secret paths now fail at the option type boundary, before the
  # service assertions can be inspected.
  assert !(builtins.tryEval invalid.modules.services.tailscale.keyFile).success;
  assert !lib.hasInfix "disable_certs" plain.services.caddy.globalConfig;
  assert plain.services.tailscale.enable == false && plain.services.gitea.enable == false;
  assert independent.services.caddy.virtualHosts == {};
  assert giteaAlone.networking.firewall.allowedTCPPorts == host.config.networking.firewall.allowedTCPPorts;
  assert !giteaDisabled.services.gitea.enable;
  assert independent.services.gitea.stateDir == "/data/apps/gitea";
  assert independent.services.gitea.database.type == "sqlite3";
  assert independent.services.gitea.settings.mailer.ENABLED;
  assert !independent.services.gitea.dump.enable;
  assert giteaNative.services.gitea.stateDir == "/srv/git";
  assert giteaNative.services.gitea.user == "forge" && giteaNative.services.gitea.group == "forge";
  assert giteaNative.services.gitea.appName == "Consumer Forge" && !giteaNative.services.gitea.lfs.enable;
  assert giteaNative.services.gitea.database.type == "postgres" && !giteaNative.services.gitea.database.createDatabase;
  assert giteaNative.services.gitea.dump.enable && giteaNative.services.gitea.dump.interval == "daily";
  assert giteaNative.services.gitea.dump.file == "consumer-dump" && giteaNative.services.gitea.dump.type == "tar.gz";
  assert giteaNative.services.gitea.settings.server.PROTOCOL == "https" && giteaNative.services.gitea.settings.server.DOMAIN == "native.example.invalid";
  assert !giteaNative.services.gitea.settings.server.DISABLE_SSH && !giteaNative.services.gitea.settings.server.DISABLE_ROUTER_LOG;
  assert giteaNative.services.gitea.settings.database.LOG_SQL && !giteaNative.services.gitea.settings.service.ENABLE_BASIC_AUTHENTICATION;
  assert giteaNative.services.gitea.settings.log.LEVEL == "Warn";
  assert giteaNative.services.gitea.settings.security.LOGIN_REMEMBER_DAYS == 7;
  assert giteaNative.services.gitea.settings.security.PASSWORD_HASH_ALGO == "argon2";
  assert giteaNative.services.gitea.settings.security.MIN_PASSWORD_LENGTH == 16;
  assert !giteaNative.services.gitea.settings.mailer.ENABLED;
  assert giteaNative.services.gitea.settings.mailer.MAILER_TYPE == "smtp" && giteaNative.services.gitea.settings.mailer.FROM == "forge@example.invalid";
  assert giteaNative.services.gitea.settings.mailer.SENDMAIL_PATH == "/run/current-system/sw/bin/sendmail";
  assert giteaNative.services.gitea.settings.other.SHOW_FOOTER_VERSION;
  assert !(lib.elem 8890 independent.networking.firewall.allowedTCPPorts);
  assert independent.services.gitea.settings.server.HTTP_PORT != 3301;
  assert !lib.hasInfix ":8890" independent.services.gitea.settings.server.ROOT_URL;
  assert server.HTTP_PORT == 3301 && server.ROOT_URL == "https://git.example.ts.net:8890/";
  assert profile.services.tailscale.enable && profile.services.tailscale.permitCertUid == profile.services.caddy.user;
  assert lib.elem 8890 profile.networking.firewall.allowedTCPPorts;
  assert overridden.services.tailscale.permitCertUid == "proxy";
  assert lib.hasInfix "http://[::1]:3456" overridden.services.caddy.virtualHosts."git.example.ts.net:443".extraConfig;
  assert overridden.services.gitea.settings.server.ROOT_URL == "https://git.example.ts.net:443/";
    runCommand "network-service-integration-check" {
      nativeBuildInputs = [bash coreutils jq caddy mockTailscale mockSleep mockNotify];
    } ''
      export COUNT_FILE="$TMPDIR/count" ARGV_FILE="$TMPDIR/argv" READY_FILE="$TMPDIR/ready"
      export FIXTURE_OFFLINE=1
      # A successful shell exit without READY does not activate a Type=notify unit;
      # systemd's failure/timeout path is configured to retry it above.
      ${bash}/bin/bash -euo pipefail ${script}
      test ! -e "$READY_FILE"
      test ! -e "$ARGV_FILE"
      rm "$COUNT_FILE"
      export FIXTURE_OFFLINE=0
      ${bash}/bin/bash -euo pipefail ${script}
      test -f "$READY_FILE"
      cmp ${expectedArgs} "$ARGV_FILE"
      test "$(cat "$COUNT_FILE")" = 3

      export IP_DIR="$TMPDIR/IP directory"
      mkdir "$IP_DIR"
      printf 'old address\n' > "$IP_DIR/ip"
      rm "$COUNT_FILE"
      ${bash}/bin/bash -euo pipefail ${ipScript}
      test "$(cat "$COUNT_FILE")" = 3
      test "$(cat "$IP_DIR/ip")" = 'TAILSCALE_IP=198.51.100.7'
      test "$(stat -c %a "$IP_DIR/ip")" = 644
      test "$(find "$IP_DIR" -type f | wc -l)" = 1

      caddy adapt --adapter caddyfile --config ${caddyfile plain} > plain.json
      caddy adapt --adapter caddyfile --config ${caddyfile profile} > profile.json
      caddy adapt --adapter caddyfile --config ${caddyfile overridden} > overridden.json
      jq -e '[.apps.http.servers[] | .automatic_https.disable_certificates // false] | all(. == false)' plain.json profile.json
      jq -e '.apps.tls.automation.policies | any(.get_certificate // [] | any(.via == "tailscale"))' profile.json
      touch "$out"
    ''
