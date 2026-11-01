{
  config,
  hey,
  lib,
  pkgs,
  ...
}: let
  inherit (hey.lib) mkBoolOpt' mkOpt';
  cfg = config.modules.agents.memory;
  paths = import ../../../lib/internal/file-contracts.nix {inherit lib;};
  adapter = pkgs.callPackage ../../../packages/agent-memory.nix {};
  core = pkgs.callPackage ../../../packages/tencent-memory-core.nix {};
  command = "${adapter}/bin/nixi-agent-memory";
  hm = config.home-manager.users.${config.user.name};
  coreConfig = pkgs.writeText "nixi-memory-core.json" (builtins.toJSON {
    deployMode = "standalone";
    server = {
      host = "127.0.0.1";
      port = cfg.port;
      corsOrigins = [];
    };
    llm = {
      baseUrl = "http://127.0.0.1:9/v1";
      apiKey = "";
      model = "disabled";
    };
    memory = {
      capture.enabled = false;
      extraction.enabled = false;
      pipeline.enableWarmup = false;
      llm.enabled = false;
      embedding = {
        provider = "none";
        enabled = false;
      };
      bm25 = {
        enabled = true;
        language = "en";
      };
    };
    skill.enabled = false;
    observability = {
      otel.enabled = false;
      clickhouse.enabled = false;
      kafka.enabled = false;
      langfuse.enabled = false;
    };
  });
  serviceArgs = [
    command
    "serve"
    "--state"
    cfg.stateDirectory
    "--port"
    (toString cfg.port)
    "--core"
    "${core}/bin/tencent-memory-core"
    "--config"
    (toString coreConfig)
  ];
in {
  options.modules.agents.memory = {
    enable = mkBoolOpt' false "Enable local authenticated Tencent MemoryCore with explicit on-demand notes, not a model proxy.";
    configureCodex = mkBoolOpt' true "Register one owned MCP entry when Codex is enabled, preserving model/auth settings.";
    stateDirectory = mkOpt' paths.runtimeSecretPath "${config.home.stateDir}/nixi-agent-memory" "Private runtime state outside the store (SQLite, logs, generated gateway token).";
    port = mkOpt' (lib.types.ints.between 1024 65535) 8420 "Loopback-only MemoryCore port.";
  };
  config = lib.mkIf cfg.enable {
    user.packages = [adapter];
    hey.capabilities.agents.memory.commands = ["nixi-agent-memory"];
    home-manager.users.${config.user.name} = lib.mkMerge [
      {
        home.activation.configureTencentMemory =
          lib.mkIf (cfg.configureCodex && config.modules.agents.codex.enable)
          (hm.lib.dag.entryAfter ["writeBoundary"] ''
            run ${command} register \
              --codex-home ${lib.escapeShellArg config.modules.agents.codex.codexHome} \
              --command ${lib.escapeShellArg command} \
              --state ${lib.escapeShellArg cfg.stateDirectory} --port ${toString cfg.port}
          '');
      }
      (lib.mkIf pkgs.stdenv.isDarwin {
        launchd.agents.nixi-agent-memory = {
          enable = true;
          config = {
            ProgramArguments = serviceArgs;
            RunAtLoad = true;
            KeepAlive = true;
            ThrottleInterval = 15;
            ProcessType = "Background";
            # Decimal equivalent of octal 077; all runtime artifacts are private.
            Umask = 63;
          };
        };
      })
      (lib.mkIf pkgs.stdenv.isLinux {
        systemd.user.services.nixi-agent-memory = {
          Unit.Description = "Local Tencent MemoryCore (no model proxy)";
          Service = {
            ExecStart = lib.escapeShellArgs serviceArgs;
            Restart = "on-failure";
            RestartSec = 15;
            UMask = "0077";
            NoNewPrivileges = true;
          };
          Install.WantedBy = ["default.target"];
        };
      })
    ];
  };
}
