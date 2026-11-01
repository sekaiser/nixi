{
  config,
  hey,
  lib,
  pkgs,
  ...
}: let
  inherit (builtins) toJSON;
  inherit (lib) mkIf optional optionalAttrs;
  inherit (lib.types) attrsOf bool int nullOr package str submodule;
  inherit (hey.lib) mkBoolOpt' mkOpt mkOpt';

  cfg = config.modules.agents.omp;
  yaml = pkgs.formats.yaml {};
  python = pkgs.callPackage ../../../packages/hey-python.nix {};
  paths = import ../../../lib/internal/file-contracts.nix {inherit lib;};
in {
  options.modules.agents.omp = {
    enable = mkBoolOpt' false "Whether to expose oh-my-pi/omp as an agent harnessing tool.";
    package = mkOpt' (nullOr package) null "Optional omp package to install. Leave null when omp is installed outside Nix.";
    command = mkOpt' str "omp" "omp command name expected on PATH.";
    stateDir = mkOpt' str "${config.home.dir}/.omp" "Existing omp state directory. This module does not manage files inside it.";
    configFile = mkOpt' (lib.types.addCheck str paths.relative) ".omp/agent/config.yml" "Writable omp config file relative to the user's home directory.";
    manageConfig = mkBoolOpt' true "Synchronise declared defaults into private writable OMP settings at user activation, preserving undeclared settings and runtime state.";
    checkCommand = mkOpt' bool true "Whether `hey doctor agents` should require the omp command on PATH.";
    checkStateDir = mkOpt' bool true "Whether `hey doctor agents` should require the existing omp state directory.";
    checkConfig = mkOpt bool true;
    webSearchProvider = mkOpt' (nullOr str) null "omp web search provider. Defaults to codex when the Codex agent module is enabled.";
    configureCodexModels = mkBoolOpt' true "Whether to add default Codex model roles when the Codex agent module is enabled.";
    codexModel = mkOpt' str "openai-codex/gpt-5.5:medium" "Default omp Codex model role value.";
    modelRoles = mkOpt' (attrsOf str) {} "Additional omp model roles.";
    symbolPreset = mkOpt' str "unicode" "omp symbol preset.";
    setupVersion = mkOpt' int 1 "omp setup version.";
    theme = mkOpt' (submodule {
      options = {
        dark = mkOpt' str "titanium" "Dark omp theme name.";
        light = mkOpt' str "light" "Light omp theme name.";
      };
    }) {} "omp theme names, with independently overridable defaults.";
  };

  config = mkIf cfg.enable (let
    codexEnabled = config.modules.agents.codex.enable;
    webSearchProvider =
      if cfg.webSearchProvider != null
      then cfg.webSearchProvider
      else if codexEnabled
      then "codex"
      else null;
    modelRoles =
      optionalAttrs (codexEnabled && cfg.configureCodexModels) {
        slow = cfg.codexModel;
      }
      // cfg.modelRoles;
    settings =
      {
        inherit (cfg) symbolPreset theme setupVersion;
      }
      // optionalAttrs (webSearchProvider != null) {providers.webSearch = webSearchProvider;}
      // optionalAttrs (modelRoles != {}) {inherit modelRoles;};
  in {
    user.packages = optional (cfg.package != null) cfg.package;

    home.dataFile = lib.mkMerge [
      {
        "hey/agents/omp.json".text = toJSON {
          inherit (cfg) configFile checkConfig;
          configManaged = cfg.manageConfig;
          inherit webSearchProvider modelRoles;
        };
      }
      (mkIf cfg.manageConfig {
        "hey/agents/omp-defaults.yml".source = yaml.generate "omp-declarative-defaults.yml" settings;
      })
    ];

    hey.capabilities.agents.omp = {
      commands = optional cfg.checkCommand cfg.command;
      directories = optionalAttrs cfg.checkStateDir {
        "omp state directory" = cfg.stateDir;
      };
      files = optionalAttrs cfg.checkConfig {
        "omp config file exists" = "${config.home.dir}/${cfg.configFile}";
      };
    };

    # OMP resolves symlinks before atomically saving settings with mode 0600.
    # Its mutable config must never point into the store (even under sudo).
    home-manager.users.${config.user.name}.home.activation.syncOmpConfig =
      mkIf cfg.manageConfig
      (config.home-manager.users.${config.user.name}.lib.dag.entryAfter ["writeBoundary"] ''
        run ${python}/bin/python3 -I ${../../../tools/sync_omp_config.py} \
          --defaults ${yaml.generate "omp-declarative-defaults.yml" settings} \
          --config ${lib.escapeShellArg "${config.home.dir}/${cfg.configFile}"}
      '');
  });
}
