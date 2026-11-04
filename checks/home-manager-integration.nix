{
  nixi,
  lib,
  runCommand,
  git,
  bash,
  coreutils,
  replaceVars,
  writeText,
  ...
}: let
  outputs = nixi.lib.mkHostFlake {
    inputs = {
      self.outPath = ./fixtures/cli-host;
      inherit nixi;
    };
    nixpkgsConfig.allowUnfree = true;
    overlays.probe = _: _: {nixiHomeProbe = "consumer-overlay";};
    hosts = lib.genAttrs ["darwin" "linux"] (name: {
      system =
        if name == "darwin"
        then "aarch64-darwin"
        else "x86_64-linux";
      module = _: {
        config = {
          user.name = "alice";
          user.home =
            if name == "darwin"
            then "/Users/alice"
            else "/home/alice";
          home.stateVersion = "26.05";
          home.configFile.probe.text = "managed fixture";
          hey.enable = true;
          system.stateVersion =
            if name == "darwin"
            then 6
            else "26.05";
          home-manager.users.alice = {pkgs, ...}: {
            home.sessionVariables.NIXI_PROBE = pkgs.nixiHomeProbe;
            home.sessionVariables.NIXI_UNFREE = builtins.toJSON pkgs.config.allowUnfree;
          };
          users.users.bob.home =
            if name == "darwin"
            then "/Users/bob"
            else "/home/bob";
          home-manager.users.bob = {
            home.stateVersion = "26.05";
            xdg.enable = true;
          };
        };
      };
    });
  };
  hosts = [outputs.darwinConfigurations.darwin outputs.nixosConfigurations.linux];
  paths = config: let
    hm = config.home-manager.users.alice;
  in {
    bin = [config.home.binDir hm.home.sessionVariables.XDG_BIN_HOME hm.xdg.binHome];
    config = [config.home.configDir hm.home.sessionVariables.XDG_CONFIG_HOME hm.xdg.configHome];
    cache = [config.home.cacheDir hm.home.sessionVariables.XDG_CACHE_HOME hm.xdg.cacheHome];
    data = [config.home.dataDir hm.home.sessionVariables.XDG_DATA_HOME hm.xdg.dataHome];
    state = [config.home.stateDir hm.home.sessionVariables.XDG_STATE_HOME hm.xdg.stateHome];
  };
  aligned = values: lib.all (xs: lib.all (x: x == builtins.head xs) xs) (builtins.attrValues values);
  checkHost = host: let
    native =
      (host.extendModules {
        modules = [
          {
            home-manager.users.alice.xdg = {
              binHome = "/custom/bin";
              configHome = "/custom/config";
              cacheHome = "/custom/cache";
              dataHome = "/custom/data";
              stateHome = "/custom/state";
            };
          }
        ];
      })
      .config;
    legacy =
      (host.extendModules {
        modules = [
          {
            home = {
              binDir = "/legacy/bin";
              configDir = "/legacy/config";
              cacheDir = "/legacy/cache";
              dataDir = "/legacy/data";
              stateDir = "/legacy/state";
            };
          }
        ];
      })
      .config;
    priority =
      (host.extendModules {
        modules = [
          {
            home.configDir = lib.mkDefault "/default/config";
            home.binDir = lib.mkDefault "/default/bin";
            home-manager.users.alice.xdg.configHome = "/native/config";
            home-manager.users.alice.xdg.binHome = "/native/bin";
          }
        ];
      })
      .config;
    movedHost = host.extendModules {
      modules = [
        {
          users.users.alice.home = lib.mkForce "/custom/alice";
          modules.agents.codex.enable = true;
          modules.agents.omp.enable = true;
          modules.agents.omp.manageConfig = true;
          modules.services.ssh.userCertificates.fixture.caKeyFile = "/fixture/ca";
        }
      ];
    };
    moved = movedHost.config;
    customPaths =
      (movedHost.extendModules {
        modules = [
          {
            modules.agents.codex.codexHome = "/custom/codex";
            modules.agents.omp = {
              stateDir = "/custom/omp";
              configFile = ".config/omp/custom.yml";
            };
            modules.services.ssh.userCertificates.fixture = {
              publicKeyFile = "/custom/key.pub";
              certificateFile = "/custom/key-cert.pub";
            };
          }
        ];
      })
      .config;
    forcedBin =
      (host.extendModules {
        modules = [
          {
            home.binDir = lib.mkForce "/forced/bin";
            home-manager.users.alice.xdg.binHome = "/native/bin";
          }
        ];
      })
      .config;
    separate =
      (host.extendModules {
        modules = [
          {
            home-manager.useGlobalPkgs = false;
            home-manager.users.alice.nixpkgs = {
              config.allowUnfree = false;
              overlays = [(_: _: {nixiHomeProbe = "separate-overlay";})];
            };
          }
        ];
      })
      .config
      .home-manager
      .users
      .alice;
    conflict =
      builtins.tryEval
      (host.extendModules {
        modules = [
          {
            home.configDir = "/legacy/config";
            home-manager.users.alice.xdg.configHome = "/conflicting/config";
          }
        ];
      })
      .config
      .home
      .configDir;
    hm = native.home-manager.users.alice;
  in
    aligned (paths host.config)
    && !lib.any (name: builtins.hasAttr name host.config.environment.variables)
    ["XDG_BIN_HOME" "XDG_CONFIG_HOME" "XDG_CACHE_HOME" "XDG_DATA_HOME" "XDG_STATE_HOME" "XDG_FAKE_HOME"]
    && host.config.home-manager.users.bob.home.sessionVariables.XDG_CONFIG_HOME == "${host.config.users.users.bob.home}/.config"
    && !lib.any (pkg: builtins.elem (lib.getName pkg) ["gcc-wrapper" "process-compose" "watchexec"]) host.config.environment.systemPackages
    && aligned (paths native)
    && aligned (paths legacy)
    && aligned (paths moved)
    && aligned (paths forcedBin)
    && moved.home.dir == "/custom/alice"
    && moved.home.binDir == "/custom/alice/.local/bin"
    && moved.home.fakeDir == "/custom/alice/.local/user"
    && moved.home.runtimeDir == "/custom/alice/.local/runtime"
    && moved.home-manager.users.alice.home.homeDirectory == "/custom/alice"
    && moved.modules.agents.codex.codexHome == "/custom/alice/.codex"
    && !(moved.env ? CODEX_HOME)
    && moved.home-manager.users.alice.home.sessionVariables.CODEX_HOME == "/custom/alice/.codex"
    && !(moved.home-manager.users.bob.home.sessionVariables ? CODEX_HOME)
    && moved.modules.agents.omp.stateDir == "/custom/alice/.omp"
    && moved.hey.capabilities.agents.omp.files."omp config file exists" == "/custom/alice/.omp/agent/config.yml"
    && !(moved.home-manager.users.alice.home.file ? ".omp/agent/config.yml")
    && lib.hasInfix "/custom/alice/.omp/agent/config.yml" moved.home-manager.users.alice.home.activation.syncOmpConfig.data
    && moved.modules.services.ssh.userCertificates.fixture.publicKeyFile == "/custom/alice/.ssh/id_ed25519.pub"
    && moved.modules.services.ssh.userCertificates.fixture.certificateFile == "/custom/alice/.ssh/id_ed25519-cert.pub"
    && customPaths.modules.agents.codex.codexHome == "/custom/codex"
    && customPaths.modules.agents.omp.stateDir == "/custom/omp"
    && customPaths.hey.capabilities.agents.omp.files."omp config file exists" == "/custom/alice/.config/omp/custom.yml"
    && lib.hasInfix "/custom/alice/.config/omp/custom.yml" customPaths.home-manager.users.alice.home.activation.syncOmpConfig.data
    && customPaths.modules.services.ssh.userCertificates.fixture.publicKeyFile == "/custom/key.pub"
    && customPaths.modules.services.ssh.userCertificates.fixture.certificateFile == "/custom/key-cert.pub"
    && forcedBin.home.binDir == "/forced/bin"
    && priority.home.binDir == "/native/bin"
    && priority.home.configDir == "/native/config"
    && native.home.configDir == "/custom/config"
    && legacy.home.configDir == "/legacy/config"
    && hm.home.sessionVariables.NIXI_PROBE == "consumer-overlay"
    && hm.home.sessionVariables.NIXI_UNFREE == "true"
    && hm.xdg.configFile.probe.target == "/custom/config/probe"
    && separate.home.sessionVariables.NIXI_PROBE == "separate-overlay"
    && separate.home.sessionVariables.NIXI_UNFREE == "false"
    && !conflict.success
    && lib.all (file: !file.force) (builtins.attrValues hm.home.file);
  brew =
    (outputs.darwinConfigurations.darwin.extendModules {
      modules = [
        {
          modules.desktop.homebrew = {
            enable = true;
            brews = ["wget"];
          };
        }
      ];
    })
    .config
    .homebrew;
  gitConfig =
    (outputs.darwinConfigurations.darwin.extendModules {
      modules = [
        {
          modules.shell.zsh.enable = true;
          modules.shell.git = {
            enable = true;
            config.sections = [
              {
                name = "fixture";
                settings = {
                  boolean = true;
                  number = 42;
                  escaped = "quote\" slash\\ newline\n";
                  omitted = null;
                };
                entries = [
                  {
                    name = "repeated";
                    value = "first";
                  }
                  {
                    name = "repeated";
                    value = "second";
                  }
                ];
              }
            ];
          };
          home-manager.users.alice.programs.git = {
            enable = true;
            settings.fixture.native = "coexists";
            ignores = ["native-ignore"];
            attributes = ["*.test text"];
          };
        }
      ];
    })
    .config
    .home-manager
    .users
    .alice;
  migrationConfig =
    (outputs.darwinConfigurations.darwin.extendModules {
      modules = [
        {
          modules.shell.git = {
            enable = true;
            profileFiles."profiles/work".text = "new profile";
          };
        }
      ];
    })
    .config;
  migration = migrationConfig.home-manager.users.alice.home.activation.migrateGitProfileParents;
  migrationScript = writeText "git-profile-migration" (builtins.replaceStrings
    ["/Users/alice/.config/git/profiles" "${outputs.darwinConfigurations.darwin.pkgs.coreutils}"]
    [''"$git_fixture/profiles"'' "${coreutils}"]
    (builtins.unsafeDiscardStringContext migration.data));
  hmShellLib = "${nixi.inputs.home-manager}/lib/bash/home-manager.sh";
  # Run the pinned native collision checker as well as the generated migration.
  # Only its environment setup and forced-path list are supplied by this fixture.
  collisionCheck = replaceVars "${nixi.inputs.home-manager}/modules/files/check-link-targets.sh" {
    initHomeManagerLib = "source ${hmShellLib}";
    storeDir = lib.escapeShellArg builtins.storeDir;
    forcedPaths = "";
  };
  oldHomeFiles = runCommand "home-manager-files" {} ''
    mkdir -p "$out/.config/git/profiles"
    printf 'old profile' > "$out/.config/git/profiles/work"
  '';
in
  assert lib.all checkHost hosts;
  assert brew.enable && brew.onActivation.cleanup == "none" && !brew.onActivation.upgrade;
  assert lib.any (brew: brew.name == "wget") brew.brews;
  assert lib.hasInfix "native-ignore" gitConfig.xdg.configFile."git/ignore".text;
  assert lib.hasInfix "*.test text" gitConfig.xdg.configFile."git/attributes".text;
  assert lib.elem "writeBoundary" migration.after;
  assert lib.elem "checkFilesChanged" migration.after;
  assert migration.before == ["linkGeneration"];
  assert !migrationConfig.modules.shell.zsh.enable;
  assert migrationConfig.modules.shell.zsh.rcFiles == [];
    runCommand "home-manager-integration-check" {
      nativeBuildInputs = [git bash coreutils];
      configText = gitConfig.xdg.configFile."git/config".text;
      passAsFile = ["configText"];
    } ''
      test "$(git config --file "$configTextPath" --get fixture.native)" = coexists
      test "$(git config --file "$configTextPath" --get fixture.boolean)" = true
      test "$(git config --file "$configTextPath" --get fixture.number)" = 42
      test "$(git config --file "$configTextPath" --get fixture.escaped)" = 'quote" slash\ newline'
      test "$(git config --file "$configTextPath" --get-all fixture.repeated)" = $'first\nsecond'
      if git config --file "$configTextPath" --get fixture.omitted; then exit 1; fi

      source ${hmShellLib}
      git_fixture="$TMPDIR/home with spaces/.config/git"
      mkdir -p "$git_fixture"
      ln -s ${oldHomeFiles}/.config/git/profiles "$git_fixture/profiles"
      DRY_RUN=1 source ${migrationScript}
      unset DRY_RUN
      test -L "$git_fixture/profiles"
      test "$(cat "$git_fixture/profiles/work")" = 'old profile'

      new_files="$TMPDIR/new-files"
      mkdir -p "$new_files/.config/git/profiles"
      printf 'changed profile' > "$new_files/.config/git/profiles/work"
      if HOME="$TMPDIR/home with spaces" ${bash}/bin/bash ${collisionCheck} \
          "$new_files" "$new_files/.config/git/profiles/work"; then
        echo 'Differing profile must fail collision checking before migration' >&2
        exit 1
      fi
      test -L "$git_fixture/profiles"

      # An unchanged legacy profile passes ordinary collision checks and can
      # migrate after the write boundary. A later run is harmless.
      cp "$git_fixture/profiles/work" "$new_files/.config/git/profiles/work"
      HOME="$TMPDIR/home with spaces" ${bash}/bin/bash ${collisionCheck} \
        "$new_files" "$new_files/.config/git/profiles/work"
      source ${migrationScript}
      test ! -L "$git_fixture/profiles"
      test -f ${oldHomeFiles}/.config/git/profiles/work
      source ${migrationScript}

      # Real directories and non-HM symlinks, including other store links,
      # are user-owned and must never be removed by this migration.
      mkdir -p "$git_fixture/profiles"
      printf 'local profile' > "$git_fixture/profiles/work"
      source ${migrationScript}
      test "$(cat "$git_fixture/profiles/work")" = 'local profile'
      mv "$git_fixture/profiles" "$git_fixture/local-profiles"
      ln -s "$git_fixture/local-profiles" "$git_fixture/profiles"
      source ${migrationScript}
      test -L "$git_fixture/profiles"
      unlink "$git_fixture/profiles"
      ln -s ${coreutils} "$git_fixture/profiles"
      source ${migrationScript}
      test -L "$git_fixture/profiles"
      touch "$out"
    ''
