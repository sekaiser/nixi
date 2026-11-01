{
  nixi,
  runCommand,
  ...
}: let
  framework =
    nixi
    // {
      apps = {};
      checks = {};
    };

  outputs = nixi.lib.mkHostFlake {
    inputs =
      nixi.inputs
      // {
        self = framework;
        nixi = framework;
      };

    hosts.capability = {
      system = "aarch64-linux";
      module = {...}: {
        config = {...}: {
          user = {
            name = "capability";
            home = "/home/capability";
          };
          system.stateVersion = "26.05";
          hey.enable = true;
          home.stateVersion = "26.05";

          modules.agents = {
            codex = {
              enable = true;
              package = null;
              codexHome = "/home/capability/.codex";
              commands = ["codex-fixture"];
            };
            codegraph = {
              enable = true;
              package = null;
              command = "codegraph-fixture";
              checkCommand = false;
            };
            copilot = {
              enable = true;
              package = null;
              command = "copilot-fixture";
              checkCommand = true;
            };
            omp = {
              enable = true;
              package = null;
              command = "omp-fixture";
              stateDir = "/home/capability/.omp";
              configFile = ".omp/agent/config.yml";
              manageConfig = false;
              checkCommand = true;
              checkStateDir = false;
              checkConfig = true;
            };
            rtk = {
              enable = true;
              package = null;
              command = "rtk-fixture";
              checkCommand = true;
              configureCodex = true;
              configureCopilot = true;
            };
          };
        };
      };
    };

    systems = ["aarch64-linux"];
  };

  dataFiles = outputs.nixosConfigurations.capability.config.home.dataFile;
  agentEnabled = selected: let
    host = outputs.nixosConfigurations.capability.extendModules {
      modules = [
        ({lib, ...}: {
          modules.agents = builtins.listToAttrs (map (name: {
            inherit name;
            value.enable = lib.mkForce (name == selected);
          }) ["codex" "codegraph" "copilot" "omp" "rtk"]);
          hey.capabilities.agents = lib.mkIf (selected == "custom") {
            custom.commands = ["custom-agent"];
          };
        })
      ];
    };
  in
    host.config.hey.info.enabled.agents;
  decodeDataFile = name: builtins.fromJSON dataFiles.${name}.text;

  actual = {
    agentEnablement = map agentEnabled ["none" "codex" "codegraph" "copilot" "omp" "rtk" "custom"];
    capabilityManifest = decodeDataFile "hey/capabilities.json";
    codexManifestFields =
      builtins.attrNames (decodeDataFile "hey/agents/codex.json");
    codexExpectations = {
      inherit (decodeDataFile "hey/agents/codex.json") plugins mcpServers;
    };
    ompManifestFields =
      builtins.attrNames (decodeDataFile "hey/agents/omp.json");
    hasCodegraphManifest = dataFiles ? "hey/agents/codegraph.json";
    hasRtkCodexActivation =
      outputs.nixosConfigurations.capability.config.home-manager.users.capability.home.activation
      ? configureRtkCodex;
    hasRtkCopilotActivation =
      outputs.nixosConfigurations.capability.config.home-manager.users.capability.home.activation
      ? configureRtkCopilot;
  };

  expected = {
    agentEnablement = [false true true true true true true];
    capabilityManifest = {
      version = 1;
      groups.agents = {
        codex = {
          commands = ["codex-fixture"];
          directories."Codex state directory" = "/home/capability/.codex";
          files."Codex config file exists" = "/home/capability/.codex/config.toml";
        };
        codegraph = {
          commands = [];
          directories = {};
          files = {};
        };
        copilot = {
          commands = ["copilot-fixture"];
          directories = {};
          files = {};
        };
        omp = {
          commands = ["omp-fixture"];
          directories = {};
          files."omp config file exists" = "/home/capability/.omp/agent/config.yml";
        };
        rtk = {
          commands = ["rtk-fixture"];
          directories = {};
          files = {};
        };
      };
    };
    codexManifestFields = ["codexHome" "mcpServers" "plugins"];
    codexExpectations = {
      plugins = [];
      mcpServers = [];
    };
    ompManifestFields = ["checkConfig" "configFile" "configManaged" "modelRoles" "webSearchProvider"];
    hasCodegraphManifest = false;
    hasRtkCodexActivation = true;
    hasRtkCopilotActivation = true;
  };
in
  assert actual == expected;
    runCommand "agent-capability-manifest-check" {
      checked = builtins.toJSON actual;
    } ''
      touch "$out"
    ''
