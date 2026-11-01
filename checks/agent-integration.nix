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
    hosts = lib.genAttrs ["linux" "darwin"] (platform: {
      system =
        if platform == "linux"
        then
          (
            if pkgs.stdenv.isLinux
            then pkgs.stdenv.hostPlatform.system
            else "x86_64-linux"
          )
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
            omp.enable = true;
          };
        };
      };
    });
  };
  hosts = [outputs.nixosConfigurations.linux outputs.darwinConfigurations.darwin];
  variants = host: [
    host.config
    (host.extendModules {
      modules = [
        {
          modules.agents.omp = {
            theme.dark = "custom: theme # with punctuation";
            modelRoles.slow = "consumer/model:high";
            modelRoles."role: name" = "null\ntrue # literal";
            symbolPreset = "null";
            webSearchProvider = "provider: literal";
          };
        }
      ];
    })
    .config
    (host.extendModules {modules = [{modules.agents.codex.enable = lib.mkForce false;}];}).config
    (host.extendModules {modules = [{modules.agents.omp.configureCodexModels = false;}];}).config
  ];
  settings = cfg: builtins.fromJSON cfg.home.dataFile."hey/agents/omp-defaults.yml".source.value;
  checkHost = host: let
    cases = variants host;
    defaults = settings (builtins.elemAt cases 0);
    custom = settings (builtins.elemAt cases 1);
    noCodex = settings (builtins.elemAt cases 2);
    noModels = settings (builtins.elemAt cases 3);
    manifest = builtins.fromJSON (builtins.elemAt cases 1).home.dataFile."hey/agents/omp.json".text;
    disabled = (host.extendModules {modules = [{modules.agents.rtk.enable = lib.mkForce false;}];}).config;
    unmanaged = (host.extendModules {modules = [{modules.agents.omp.manageConfig = false;}];}).config;
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
  in
    defaults.theme
    == {
      dark = "titanium";
      light = "light";
    }
    && defaults.modelRoles.slow == host.config.modules.agents.omp.codexModel
    && custom.theme.light == "light"
    && custom.theme.dark == "custom: theme # with punctuation"
    && custom.modelRoles.slow == "consumer/model:high"
    && manifest.modelRoles == custom.modelRoles
    && !(noCodex ? modelRoles)
    && !(noCodex ? providers)
    && !(noModels ? modelRoles)
    && noModels.providers.webSearch == "codex"
    && !(unmanaged.home.file ? ".omp/agent/config.yml")
    && !(host.config.home.file ? ".omp/agent/config.yml")
    && host.config.home-manager.users.alice.home.activation ? syncOmpConfig
    && !(unmanaged.home-manager.users.alice.home.activation ? syncOmpConfig)
    && noHooks disabled
    && noHooks noIntegration;
  # Build the actual module's YAML on the runner's native platform. The other
  # platform is evaluated above, without importing build results during eval.
  native =
    if pkgs.stdenv.isDarwin
    then outputs.darwinConfigurations.darwin
    else outputs.nixosConfigurations.linux;
  files = writeText "omp-yaml-fixtures.json" (builtins.toJSON (map (cfg: {
    file = cfg.home.dataFile."hey/agents/omp-defaults.yml".source;
    expected = settings cfg;
  }) (variants native)));
  hook = config: name: writeText "rtk-${name}-activation" config.home-manager.users.alice.home.activation.${name}.data;
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
  assert lib.all checkHost hosts;
    runCommand "agent-integration-check" {
      src = ../.;
      nativeBuildInputs = [bash coreutils (python3.withPackages (ps: [ps.pyyaml]))];
    } ''
      python - ${files} <<'PY'
      import json, sys, yaml
      from pathlib import Path
      for fixture in json.loads(Path(sys.argv[1]).read_text()):
          assert yaml.safe_load(Path(fixture['file']).read_text()) == fixture['expected']
      PY
      PYTHONDONTWRITEBYTECODE=1 python "$src/test_tools/test_omp_config.py"

      source ${nixi.inputs.home-manager}/lib/bash/home-manager.sh
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
