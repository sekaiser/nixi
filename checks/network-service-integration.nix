{
  nixi,
  lib,
  bash,
  coreutils,
  jq,
  caddy,
  python3,
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
    hosts = lib.genAttrs ["server" "arm"] (name: {
      system =
        if name == "server"
        then "x86_64-linux"
        else "aarch64-linux";
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
    });
  };
  host = outputs.nixosConfigurations.server;
  extend = module: (host.extendModules {modules = [module];}).config;
  policyBlocked = cfg: lib.any (a: !a.assertion && lib.hasInfix "Gitea deployment policy" a.message) cfg.assertions;
  unselectedPolicy = extend {
    modules.services.gitea = {
      enable = true;
      domain = "git.example.invalid";
    };
  };
  policyCases = target: let
    configured = settings: (target.extendModules {modules = [settings];}).config;
    adapter.modules.services.gitea = {
      enable = true;
      domain = "git.example.invalid";
    };
    compatModule = {
      modules.profiles.gitea-compatibility.enable = true;
      modules.services.gitea.domain = "git.example.invalid";
    };
  in {
    unselected = configured adapter;
    native = configured {
      imports = [adapter];
      modules.services.gitea.deploymentPolicy = "native";
    };
    upstream = configured {
      services.gitea = {
        enable = true;
        appName = "Gitea";
        settings.server.DOMAIN = "git.example.invalid";
        settings.log.LEVEL = "Info";
      };
    };
    compat = configured compatModule;
    override = configured {
      imports = [compatModule];
      services.gitea = {
        stateDir = "/srv/review-git";
        database = {
          type = "postgres";
          createDatabase = false;
        };
        lfs.enable = false;
        settings = {
          mailer.ENABLED = false;
          service.ENABLE_BASIC_AUTHENTICATION = false;
          security = {
            LOGIN_REMEMBER_DAYS = 7;
            PASSWORD_HASH_ALGO = "argon2";
            MIN_PASSWORD_LENGTH = 16;
          };
        };
      };
    };
    disabled = map (settings: configured {imports = [compatModule settings];}) [
      {modules.services.gitea.enable = false;}
      {services.gitea.enable = false;}
    ];
    nativeDisabled = configured {
      imports = [adapter];
      services.gitea.enable = false;
    };
    ambiguous = configured {
      imports = [compatModule];
      modules.services.gitea.deploymentPolicy = "native";
    };
    tailnetNative = configured {
      imports = [profileModule];
      modules.profiles.gitea-compatibility.enable = false;
      modules.services.gitea.deploymentPolicy = "native";
    };
    nativeOwned = configured {
      imports = [compatModule];
      modules.services.gitea.enable = false;
      services.gitea = {
        enable = true;
        stateDir = "/srv/native-owned";
      };
    };
  };
  deployment = cfg: let
    g = cfg.services.gitea;
  in {
    inherit (g) stateDir customDir repositoryRoot user group appName lfs database dump settings;
  };
  policyMatrix = target: let
    cases = policyCases target;
    g = cases.compat.services.gitea;
    changed = cases.override.services.gitea;
  in
    deployment cases.native
    == deployment cases.upstream
    && !policyBlocked cases.native
    && !policyBlocked cases.compat
    && policyBlocked cases.unselected
    && policyBlocked cases.ambiguous
    && g.stateDir == "/data/apps/gitea"
    && g.database.type == "sqlite3"
    && g.database.createDatabase
    && g.lfs.enable
    && !g.dump.enable
    && g.dump.interval == "hourly"
    && g.dump.file == "gitea-dump"
    && g.dump.type == "tar.zst"
    && g.settings.mailer.ENABLED
    && g.settings.mailer.MAILER_TYPE == "sendmail"
    && g.settings.service.ENABLE_BASIC_AUTHENTICATION
    && g.settings.security.LOGIN_REMEMBER_DAYS == 31
    && g.settings.security.PASSWORD_HASH_ALGO == "scrypt"
    && g.settings.security.MIN_PASSWORD_LENGTH == 10
    && changed.stateDir == "/srv/review-git"
    && changed.database.type == "postgres"
    && !changed.database.createDatabase
    && !changed.lfs.enable
    && !changed.settings.mailer.ENABLED
    && !changed.settings.service.ENABLE_BASIC_AUTHENTICATION
    && changed.settings.security.MIN_PASSWORD_LENGTH == 16
    && lib.all (cfg: !cfg.services.gitea.enable && !policyBlocked cfg && cfg.services.gitea.stateDir == target.config.services.gitea.stateDir) cases.disabled
    && !policyBlocked cases.nativeDisabled
    && !policyBlocked cases.tailnetNative
    && cases.tailnetNative.services.gitea.stateDir == cases.upstream.services.gitea.stateDir
    && cases.tailnetNative.services.gitea.settings.mailer.ENABLED == cases.upstream.services.gitea.settings.mailer.ENABLED
    && cases.tailnetNative.services.gitea.settings.server.HTTP_ADDR == "127.0.0.1"
    && !policyBlocked cases.nativeOwned
    && cases.nativeOwned.services.gitea.stateDir == "/srv/native-owned"
    && !cases.nativeOwned.services.gitea.lfs.enable;
  policyTargets = builtins.attrValues outputs.nixosConfigurations;
  policyFixtures = writeText "gitea-deployment-fixtures.json" (builtins.toJSON (lib.concatMap (target:
    map (name: let
      cfg = (policyCases target).${name};
      g = cfg.services.gitea;
    in {
      inherit name;
      system = target.pkgs.stdenv.hostPlatform.system;
      state = g.stateDir;
      database = g.database.type;
      mailer = g.settings.mailer.ENABLED;
      ini = builtins.unsafeDiscardStringContext (''          WORK_PATH = ${g.stateDir}
        ''
        + lib.generators.toINI {} g.settings);
    }) ["native" "compat" "override"])
  policyTargets));
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
    modules.profiles.gitea-compatibility.enable = true;
    modules.services = {
      caddy.enable = true;
      gitea = {
        enable = true;
        domain = "git.example.invalid";
      };
    };
  };
  profileModule = {
    modules.profiles.gitea-tailscale = {
      enable = true;
      listenAddresses = ["100.100.100.10" "fd7a:115c:a1e0::10"];
    };
    modules.services.gitea.domain = "git.example.ts.net";
    services.caddy.virtualHosts."public.example.invalid".extraConfig = ''respond "public"'';
  };
  giteaNative = extend {
    modules.profiles.gitea-compatibility.enable = true;
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
      deploymentPolicy = "native";
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
  public = extend {
    imports = [profileModule];
    modules.profiles.gitea-tailscale.exposure = "public";
    services.caddy.virtualHosts."git.example.ts.net:8890".listenAddresses = [];
  };
  invalidExposure = settings: let
    configured = extend {imports = [profileModule settings];};
  in
    lib.any (a: !a.assertion && lib.hasInfix "gitea-tailscale" a.message) configured.assertions;
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
            ${lib.optionalString (vhost.listenAddresses != []) "bind ${lib.concatStringsSep " " vhost.listenAddresses}"}
            ${vhost.extraConfig}
          }
        '')
        cfg.services.caddy.virtualHosts)}
    '';
in
  assert lib.assertMsg (policyBlocked unselectedPolicy) "Gitea deployment policy selection must be explicit";
  assert lib.assertMsg (lib.all policyMatrix policyTargets) "Gitea deployment policy matrix failed";
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
  assert !policyBlocked profile && profile.services.gitea.stateDir == "/data/apps/gitea" && profile.services.gitea.database.type == "sqlite3" && profile.services.gitea.lfs.enable;
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
  assert !(lib.elem 8890 profile.networking.firewall.allowedTCPPorts);
  assert !profile.services.caddy.openFirewall;
  assert lib.elem 8890 profile.networking.firewall.interfaces.tailscale0.allowedTCPPorts;
  assert profile.services.caddy.virtualHosts."git.example.ts.net:8890".listenAddresses == ["100.100.100.10" "[fd7a:115c:a1e0::10]"];
  assert lib.elem 8890 public.networking.firewall.allowedTCPPorts;
  assert public.services.caddy.virtualHosts."git.example.ts.net:8890".listenAddresses == [];
  assert invalidExposure {services.caddy.openFirewall = true;};
  assert invalidExposure {networking.firewall.allowedTCPPorts = [8890];};
  assert invalidExposure {
    networking.firewall.allowedTCPPortRanges = [
      {
        from = 8800;
        to = 8900;
      }
    ];
  };
  assert invalidExposure {services.gitea.settings.server.HTTP_ADDR = "0.0.0.0";};
  assert lib.all (address: invalidExposure {services.caddy.virtualHosts."git.example.ts.net:8890".listenAddresses = [address];})
  ["0.0.0.0" "::" "100.64.999.1" "100.63.1.1" "fd7a:115c:a1e0:::1" "fd7a:115c:a1e0::1::2" "127.0.0.1"];
  assert invalidExposure {services.caddy.virtualHosts."git.example.ts.net:8890".listenAddresses = [];};
  assert overridden.services.tailscale.permitCertUid == "proxy";
  assert lib.hasInfix "http://[::1]:3456" overridden.services.caddy.virtualHosts."git.example.ts.net:443".extraConfig;
  assert overridden.services.gitea.settings.server.ROOT_URL == "https://git.example.ts.net:443/";
    runCommand "network-service-integration-check" {
      nativeBuildInputs = [bash coreutils jq caddy python3 mockTailscale mockSleep mockNotify];
    } ''
      python - ${policyFixtures} <<'PY'
      import configparser, json, sys
      for case in json.load(open(sys.argv[1])):
          ini = configparser.ConfigParser(interpolation=None)
          ini.optionxform = str
          ini.read_string('[DEFAULT]\n' + case['ini'])
          assert ini['DEFAULT']['WORK_PATH'] == case['state']
          assert ini['database']['DB_TYPE'] == case['database']
          assert ini.getboolean('mailer', 'ENABLED') == case['mailer']
          if case['name'] == 'compat':
              assert case['state'] == '/data/apps/gitea'
              assert case['database'] == 'sqlite3'
              assert ini.getboolean('service', 'ENABLE_BASIC_AUTHENTICATION')
              assert ini['security']['PASSWORD_HASH_ALGO'] == 'scrypt'
          elif case['name'] == 'override':
              assert case['state'] == '/srv/review-git' and case['database'] == 'postgres'
              assert not ini.getboolean('service', 'ENABLE_BASIC_AUTHENTICATION')
              assert ini['security']['MIN_PASSWORD_LENGTH'] == '16'
      print('PASS: native/compatibility/override Gitea settings render and parse for both Linux architectures')
      PY
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
      caddy adapt --adapter caddyfile --config ${caddyfile public} > public.json
      jq -e '[.apps.http.servers[] | .automatic_https.disable_certificates // false] | all(. == false)' plain.json profile.json
      jq -e '.apps.tls.automation.policies | any(.get_certificate // [] | any(.via == "tailscale"))' profile.json
      jq -e '[.apps.http.servers[].listen[] | select(endswith(":8890"))] | sort == ["100.100.100.10:8890", "[fd7a:115c:a1e0::10]:8890"]' profile.json
      jq -e '[.apps.http.servers[].listen[] | select(endswith(":8890"))] | any(. == ":8890")' public.json
      touch "$out"
    ''
