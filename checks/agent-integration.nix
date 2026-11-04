{
  nixi,
  lib,
  pkgs,
  bash,
  coreutils,
  python3,
  runCommand,
  writeText,
  writeShellScriptBin,
  ...
}: let
  codexHome = ''/fixture/codex home ' " $(not-expanded)'';
  rtk = writeShellScriptBin "rtk-fixture" ''
    printf '%s\n' "$@" >> "$RTK_LOG"
    printf '%s' "''${CODEX_HOME-}" > "$RTK_HOME_LOG"
  '';
  outputs = nixi.lib.mkHostFlake {
    inputs = {
      self.outPath = ./fixtures/cli-host;
      inherit nixi;
    };
    hosts = lib.genAttrs ["linux" "arm" "darwin"] (platform: {
      system =
        if platform == "darwin"
        then "aarch64-darwin"
        else if platform == "arm"
        then "aarch64-linux"
        else "x86_64-linux";
      module = _: {
        config = {
          user = {
            name = "alice";
            home = "/fixture/alice";
          };
          home.stateVersion = "26.05";
          system.stateVersion =
            if platform == "darwin"
            then 6
            else "26.05";
          users.users.bob.home = "/fixture/bob";
          home-manager.users.bob.home.stateVersion = "26.05";
          modules.agents = {
            codex = {
              enable = true;
              inherit codexHome;
            };
            copilot.enable = true;
            rtk = {
              enable = true;
              package = rtk;
              command = "rtk-fixture";
            };
          };
        };
      };
    });
  };
  hosts = [outputs.nixosConfigurations.linux outputs.nixosConfigurations.arm outputs.darwinConfigurations.darwin];
  policyCases = host: let
    extend = module: (host.extendModules {modules = [module];}).config;
    preset.modules.profiles.omp-workstation.enable = true;
  in {
    neutral = extend {modules.agents.omp.enable = true;};
    workstation = extend preset;
    custom = extend {
      imports = [preset];
      modules.agents.omp = {
        theme.dark = "custom: theme # with punctuation";
        modelRoles.slow = "consumer/model:high";
        modelRoles."role: name" = "null\ntrue # literal";
        symbolPreset = "null";
        webSearchProvider = "provider: literal";
      };
    };
    noCodex = extend {
      imports = [preset];
      modules.agents.codex.enable = lib.mkForce false;
    };
    noModels = extend {
      imports = [preset];
      modules.agents.omp.configureCodexModels = false;
    };
    noProvider = extend {
      imports = [preset];
      modules.agents.omp.webSearchProvider = null;
    };
    unmanaged = extend {
      imports = [preset];
      modules.agents.omp.manageConfig = false;
    };
    disabled = extend {
      imports = [preset];
      modules.agents.omp.enable = false;
    };
    disabledPreset = extend {
      modules.agents.omp.enable = true;
      modules.profiles.omp-workstation.enable = false;
    };
    userOwned = extend {
      modules.agents.omp.enable = true;
      home.file.".omp/agent/config.yml".text = "consumer-owned fixture";
    };
    managedEmpty = extend {
      modules.agents.omp = {
        enable = true;
        manageConfig = true;
      };
    };
    noPreferences = extend {
      imports = [preset];
      modules.agents.omp = {
        theme = {
          dark = null;
          light = null;
        };
        symbolPreset = null;
        setupVersion = null;
        webSearchProvider = null;
        configureCodexModels = false;
      };
    };
    explicit = extend {
      modules.agents.omp = {
        enable = true;
        manageConfig = true;
        package = rtk;
        command = "omp-explicit";
        stateDir = "/fixture/own-omp";
        configFile = ".config/omp/own.yml";
        checkCommand = false;
        checkStateDir = false;
        checkConfig = false;
        theme.dark = "consumer-dark";
        modelRoles.fast = "consumer/fast";
        webSearchProvider = "independent";
      };
    };
    explicitModel = extend {
      modules.agents.omp = {
        enable = true;
        manageConfig = true;
        configureCodexModels = true;
        codexModel = "consumer/slow";
      };
    };
    missingModel = extend {
      modules.agents.omp = {
        enable = true;
        configureCodexModels = true;
      };
    };
  };
  variants = host: let cases = policyCases host; in with cases; [workstation custom noCodex noModels noProvider managedEmpty noPreferences explicit explicitModel];
  settings = cfg: builtins.fromJSON cfg.home.dataFile."hey/agents/omp-defaults.yml".source.value;
  manifest = cfg: builtins.fromJSON cfg.home.dataFile."hey/agents/omp.json".text;
  noOmpHook = cfg: !(cfg.home-manager.users.alice.home.activation ? syncOmpConfig);
  neutral = cfg:
    !cfg.modules.agents.omp.manageConfig
    && !(cfg.home.dataFile ? "hey/agents/omp-defaults.yml")
    && noOmpHook cfg
    && (manifest cfg).webSearchProvider == null
    && (manifest cfg).modelRoles == {};
  checkHost = host: let
    cases = policyCases host;
    defaults = settings cases.workstation;
    custom = settings cases.custom;
    noCodex = settings cases.noCodex;
    noModels = settings cases.noModels;
    disabled = (host.extendModules {modules = [{modules.agents.rtk.enable = lib.mkForce false;}];}).config;
    noIntegration =
      (host.extendModules {
        modules = [
          {
            modules.agents.rtk = {
              configureCodex = false;
              configureCopilot = false;
            };
          }
        ];
      })
      .config;
    noHooks = cfg: let
      activation = cfg.home-manager.users.alice.home.activation;
    in
      !(activation ? configureRtkCodex) && !(activation ? configureRtkCopilot);
    checks = {
      neutral = neutral cases.neutral && neutral cases.disabledPreset && !(cases.neutral.home.file ? ".omp/agent/config.yml");
      workstation =
        defaults
        == {
          theme = {
            dark = "titanium";
            light = "light";
          };
          symbolPreset = "unicode";
          setupVersion = 1;
          providers.webSearch = "codex";
          modelRoles.slow = "openai-codex/gpt-5.5:medium";
        };
      custom =
        custom.theme.light
        == "light"
        && custom.theme.dark == "custom: theme # with punctuation"
        && custom.modelRoles.slow == "consumer/model:high"
        && (manifest cases.custom).modelRoles == custom.modelRoles;
      noCodex = !(noCodex ? modelRoles) && !(noCodex ? providers);
      noModels = !(noModels ? modelRoles) && noModels.providers.webSearch == "codex";
      omissions =
        !(settings cases.noProvider ? providers)
        && settings cases.managedEmpty == {}
        && settings cases.noPreferences == {};
      explicit =
        settings cases.explicit
        == {
          theme.dark = "consumer-dark";
          providers.webSearch = "independent";
          modelRoles.fast = "consumer/fast";
        };
      explicitModel =
        settings cases.explicitModel
        == {modelRoles.slow = "consumer/slow";}
        && lib.any (a: !a.assertion && lib.hasPrefix "OMP configureCodexModels requires" a.message) cases.missingModel.assertions;
      package = lib.elem rtk cases.explicit.users.users.alice.packages;
      capabilities =
        cases.explicit.hey.capabilities.agents.omp
        == {
          commands = [];
          directories = {};
          files = {};
        };
      paths =
        (manifest cases.explicit).configFile
        == ".config/omp/own.yml"
        && cases.explicit.modules.agents.omp.stateDir == "/fixture/own-omp";
      unmanaged =
        !(cases.unmanaged.home.file ? ".omp/agent/config.yml")
        && noOmpHook cases.unmanaged
        && !(cases.unmanaged.home.dataFile ? "hey/agents/omp-defaults.yml")
        && !(manifest cases.unmanaged).configManaged;
      disabled =
        noOmpHook cases.disabled
        && !(cases.disabled.home.dataFile ? "hey/agents/omp.json")
        && !(cases.disabled.home.dataFile ? "hey/agents/omp-defaults.yml");
      userOwned =
        cases.userOwned.home.file.".omp/agent/config.yml".text
        == "consumer-owned fixture"
        && noOmpHook cases.userOwned;
      isolation =
        cases.workstation.home-manager.users.alice.home.activation ? syncOmpConfig
        && !(cases.workstation.home-manager.users.bob.home.activation ? syncOmpConfig)
        && (!(cases.workstation.home-manager.users ? root) || !(cases.workstation.home-manager.users.root.home.activation ? syncOmpConfig));
      rtk = noHooks disabled && noHooks noIntegration;
    };
  in
    lib.all (name: lib.assertMsg checks.${name} "${host.pkgs.stdenv.hostPlatform.system} OMP ${name} policy failed") (builtins.attrNames checks);
  # Build the actual module's YAML on the runner's native platform. Other
  # targets are evaluated above, without importing build results during eval.
  native =
    if pkgs.stdenv.isDarwin
    then outputs.darwinConfigurations.darwin
    else if pkgs.stdenv.hostPlatform.system == "aarch64-linux"
    then outputs.nixosConfigurations.arm
    else outputs.nixosConfigurations.linux;
  files = writeText "omp-yaml-fixtures.json" (builtins.toJSON (map (cfg: {
    file = cfg.home.dataFile."hey/agents/omp-defaults.yml".source;
    expected = settings cfg;
  }) (variants native)));
  hook = config: name: writeText "rtk-${name}-activation" config.home-manager.users.alice.home.activation.${name}.data;
  ompConfig = (policyCases native).workstation;
  ompActivation =
    lib.replaceStrings
    [(lib.escapeShellArg "${ompConfig.home.dir}/${ompConfig.modules.agents.omp.configFile}")]
    [''"$OMP_FIXTURE_CONFIG"'']
    ompConfig.home-manager.users.alice.home.activation.syncOmpConfig.data;
  ompHook = writeText "omp-activation-fixture" ompActivation;
  missing =
    (native.extendModules {
      modules = [
        {
          modules.agents.rtk = {
            package = lib.mkForce null;
            command = lib.mkForce "/no-such-rtk-fixture";
          };
        }
      ];
    })
    .config;
in
  assert lib.assertMsg (lib.all (host: neutral (policyCases host).neutral) hosts) "Generic OMP enablement must leave mutable settings unmanaged";
  assert lib.all checkHost hosts;
  assert lib.hasInfix ''--config "$OMP_FIXTURE_CONFIG"'' ompActivation;
    runCommand "agent-integration-check" {
      src = ../.;
      nativeBuildInputs = [bash coreutils (python3.withPackages (ps: [ps.pyyaml]))];
      # The disposable real-root VM consumes the exact generated hook without
      # building this check or changing the production helper's trust policy.
      passthru.ompActivationFixture = ompHook;
    } ''
      python - ${files} <<'PY'
      import json, sys, yaml
      from pathlib import Path
      for fixture in json.loads(Path(sys.argv[1]).read_text()):
          assert yaml.safe_load(Path(fixture['file']).read_text()) == fixture['expected']
      PY
      PYTHONDONTWRITEBYTECODE=1 python "$src/test_tools/test_omp_config.py"

      source ${nixi.inputs.home-manager}/lib/bash/home-manager.sh
      export OMP_FIXTURE_CONFIG="$TMPDIR/OMP settings/agent/config.yml"
      DRY_RUN=1 source ${ompHook}
      unset DRY_RUN
      test ! -e "$TMPDIR/OMP settings"
      mkdir -p "$(dirname "$OMP_FIXTURE_CONFIG")"
      chmod 700 "$TMPDIR/OMP settings" "$(dirname "$OMP_FIXTURE_CONFIG")"
      printf 'privateExample: SYNTHETIC_PRIVATE\nstartup:\n  quiet: true\n' > "$OMP_FIXTURE_CONFIG"
      chmod 600 "$OMP_FIXTURE_CONFIG"
      cp "$OMP_FIXTURE_CONFIG" "$TMPDIR/omp-before.yml"
      # A Linux user-namespace sandbox may map '/' to UID65534. That is an
      # actually untrusted ancestor for the unmodified recipient helper. Keep
      # this subprocess boundary real; only in-process unit fixtures model host
      # ancestry. Positive generated-hook acceptance also runs in the guest.
      omp_trusted_ancestry=1
      python - "$OMP_FIXTURE_CONFIG" <<'PY' || omp_trusted_ancestry=0
      import os, stat, sys
      from pathlib import Path
      path = Path(sys.argv[1]).parent
      for parent in [*reversed(path.parents), path]:
          info = parent.stat(follow_symlinks=False)
          sticky = info.st_uid == 0 and info.st_mode & stat.S_ISVTX
          if (not stat.S_ISDIR(info.st_mode) or info.st_uid not in (0, os.getuid())
                  or (info.st_mode & 0o022 and not sticky)):
              raise SystemExit(1)
      PY
      if [ "$omp_trusted_ancestry" = 1 ]; then
        source ${ompHook}
        cp "$OMP_FIXTURE_CONFIG" "$TMPDIR/omp-first.yml"
        source ${ompHook}
        cmp "$OMP_FIXTURE_CONFIG" "$TMPDIR/omp-first.yml"
      python - "$OMP_FIXTURE_CONFIG" <<'PY'
      import json, os, stat, sys, yaml
      from pathlib import Path
      path = Path(sys.argv[1])
      assert not path.is_symlink()
      assert path.stat().st_uid == os.getuid()
      assert stat.S_IMODE(path.stat().st_mode) == 0o600
      data = yaml.safe_load(path.read_text())
      assert data['privateExample'] == 'SYNTHETIC_PRIVATE'
      assert data['startup']['quiet'] is True
      assert data['theme'] == {'dark': 'titanium', 'light': 'light'}
      assert data['modelRoles']['slow'] == 'openai-codex/gpt-5.5:medium'
      metadata = path.with_name(path.name + '.nixi-managed.json')
      assert 'privateExample' not in json.loads(metadata.read_text())
      assert stat.S_IMODE(metadata.stat().st_mode) == 0o600
      print('PASS: opt-in OMP activation respects dry runs and preserves private writable user settings')
      PY
      else
        if (source ${ompHook}); then
          echo 'Untrusted real ancestry must fail generated OMP activation' >&2
          exit 1
        fi
        cmp "$OMP_FIXTURE_CONFIG" "$TMPDIR/omp-before.yml"
        test ! -e "$OMP_FIXTURE_CONFIG.nixi-managed.json"
        test ! -e "$OMP_FIXTURE_CONFIG.nixi-lock"
        echo 'PASS: unmodified OMP activation refuses untrusted sandbox ancestry and preserves state'
        echo 'SCOPE: positive generated OMP activation requires the disposable real-root guest'
      fi
      export RTK_LOG="$TMPDIR/rtk-log" RTK_HOME_LOG="$TMPDIR/rtk-home"
      export CODEX_HOME=/stale/codex
      ${lib.concatMapStringsSep "\n" (host: ''
          DRY_RUN=1 source ${hook host.config "configureRtkCodex"}
          unset DRY_RUN
          test ! -e "$RTK_LOG"
          source ${hook host.config "configureRtkCodex"}
          test "$(cat "$RTK_HOME_LOG")" = ${lib.escapeShellArg codexHome}
          test "$(cat "$RTK_LOG")" = $'init\n-g\n--codex'
          test "$CODEX_HOME" = /stale/codex
          rm "$RTK_LOG" "$RTK_HOME_LOG"
          DRY_RUN=1 source ${hook host.config "configureRtkCopilot"}
          unset DRY_RUN
          test ! -e "$RTK_LOG"
          source ${hook host.config "configureRtkCopilot"}
          test "$(cat "$RTK_LOG")" = $'init\n-g\n--copilot'
          rm "$RTK_LOG" "$RTK_HOME_LOG"
        '')
        hosts}
      DRY_RUN=1 source ${hook missing "configureRtkCodex"}
      unset DRY_RUN
      if (source ${hook missing "configureRtkCodex"}); then
        echo 'Missing RTK must fail a live activation' >&2
        exit 1
      fi
      test ! -e "$RTK_LOG"
      touch "$out"
    ''
