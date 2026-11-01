{
  nixi,
  lib,
  coreutils,
  bash,
  writeText,
  runCommand,
  ...
}: let
  outputs = nixi.lib.mkHostFlake {
    inputs = {
      self.outPath = ./fixtures/cli-host;
      inherit nixi;
    };
    hosts = lib.genAttrs ["linux" "darwin"] (platform: {
      system =
        if platform == "linux"
        then "x86_64-linux"
        else "aarch64-darwin";
      module = _: {
        config = {
          user = {
            name = "alice";
            home = "/fixture/alice";
          };
          home.stateVersion = "26.05";
          system.stateVersion =
            if platform == "linux"
            then "26.05"
            else 6;
          modules.shell.gnupg = {
            enable = true;
            cacheTTL = 7200;
          };
          home-manager.users.alice.xdg.configHome = "/fixture/alice/custom config";
        };
      };
    });
  };
  hosts = [outputs.nixosConfigurations.linux outputs.darwinConfigurations.darwin];
  valid = host: let
    config = host.config;
    hm = config.home-manager.users.alice;
    homedir = hm.programs.gpg.homedir;
    agent = hm.home.file."${homedir}/gpg-agent.conf".text;
    pinentry =
      if host.pkgs.stdenv.isDarwin
      then host.pkgs.pinentry_mac
      else host.pkgs.pinentry-curses;
    override =
      (host.extendModules {
        modules = [
          {
            home-manager.users.alice = {
              programs.gpg.homedir = "/fixture/override";
              services.gpg-agent.defaultCacheTtl = 900;
            };
          }
        ];
      })
      .config
      .home-manager
      .users
      .alice;
    disabled =
      (host.extendModules {
        modules = [
          {
            home-manager.users.alice = {
              programs.gpg.enable = false;
              services.gpg-agent.enable = false;
            };
          }
        ];
      }).config.home-manager.users.alice;
  in
    hm.programs.gpg.enable
    && hm.services.gpg-agent.enable
    && homedir == "/fixture/alice/custom config/gnupg"
    && hm.home.sessionVariables.GNUPGHOME == homedir
    && lib.hasInfix "default-cache-ttl 7200" agent
    && lib.hasInfix (builtins.unsafeDiscardStringContext (lib.getExe pinentry)) agent
    && !(lib.hasInfix "/opt/homebrew" agent)
    && !config.programs.gnupg.agent.enable
    && !(config.system.activationScripts ? setPermissionsGnupg)
    && override.home.sessionVariables.GNUPGHOME == "/fixture/override"
    && override.services.gpg-agent.defaultCacheTtl == 900
    && !disabled.programs.gpg.enable
    && !(disabled.home.activation ? createGpgHomedir)
    && !(disabled.home.activation ? secureGpgHomedir)
    && (
      if host.pkgs.stdenv.isDarwin
      then hm.launchd.agents.gpg-agent.config.EnvironmentVariables.GNUPGHOME == homedir
      else hm.systemd.user.services.gpg-agent.Service.Environment == ["GNUPGHOME=${homedir}"]
    );
  fixture = host: let
    hm = host.config.home-manager.users.alice;
    script = hm.home.activation.createGpgHomedir.data + hm.home.activation.secureGpgHomedir.data;
  in
    writeText "gnupg-permissions-${host.pkgs.stdenv.hostPlatform.system}" (''
        set -eu
        VERBOSE_ARG=
        run() { "$@"; }
      ''
      + builtins.replaceStrings
      [(lib.escapeShellArg hm.programs.gpg.homedir) "${host.pkgs.coreutils}/bin/chmod"]
      [''"$PWD/keys"'' "${coreutils}/bin/chmod"]
      (builtins.unsafeDiscardStringContext script));
in
  assert lib.all valid hosts;
    runCommand "gnupg-check" {nativeBuildInputs = [coreutils bash];} ''
      ${lib.concatMapStringsSep "\n" (host: ''
          mkdir ${host.pkgs.stdenv.hostPlatform.system}
          (
            cd ${host.pkgs.stdenv.hostPlatform.system}
            ${bash}/bin/bash ${fixture host}
            test "$(stat -c %a keys)" = 700
            touch keys/keyring
            chmod 644 keys/keyring
            chmod 755 keys
            ${bash}/bin/bash ${fixture host}
            test "$(stat -c %a keys)" = 700
            test "$(stat -c %a keys/keyring)" = 644
            mv keys real-keys
            mkdir untouched
            chmod 755 untouched
            ln -s untouched keys
            if ${bash}/bin/bash ${fixture host}; then exit 1; fi
            test "$(stat -c %a untouched)" = 755
          )
        '')
        hosts}
      touch "$out"
    ''
