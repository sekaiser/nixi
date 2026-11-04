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
    manageConfig = mkBoolOpt' false "Opt into synchronising declared defaults into private writable OMP settings at user activation, preserving undeclared settings and runtime state.";
    checkCommand = mkOpt' bool true "Whether `hey doctor agents` should require the omp command on PATH.";
    checkStateDir = mkOpt' bool true "Whether `hey doctor agents` should require the existing omp state directory.";
    checkConfig = mkOpt bool true;
    webSearchProvider = mkOpt' (nullOr str) null "Optional omp web search provider. Enabling Codex alone does not select one.";
    configureCodexModels = mkBoolOpt' false "Explicitly add a default slow model role when Codex is enabled. Requires codexModel; explicit modelRoles take precedence.";
    codexModel = mkOpt' (nullOr str) null "Explicit omp Codex model role value. The omp-workstation preset supplies its compatibility default.";
    modelRoles = mkOpt' (attrsOf str) {} "Additional omp model roles.";
    symbolPreset = mkOpt' (nullOr str) null "Optional omp symbol preset; null leaves it undeclared.";
    setupVersion = mkOpt' (nullOr int) null "Optional omp setup version; null leaves it undeclared.";
    theme = mkOpt' (submodule {
      options = {
        dark = mkOpt' (nullOr str) null "Optional dark omp theme name.";
        light = mkOpt' (nullOr str) null "Optional light omp theme name.";
      };
    }) {} "omp theme names, with independently overridable defaults.";
  };

  config = mkIf cfg.enable (let
    codexEnabled = config.modules.agents.codex.enable;
    webSearchProvider = cfg.webSearchProvider;
    modelRoles =
      optionalAttrs (codexEnabled && cfg.configureCodexModels && cfg.codexModel != null) {
        slow = cfg.codexModel;
      }
      // cfg.modelRoles;
    theme = lib.filterAttrs (_: value: value != null) cfg.theme;
    settings =
      optionalAttrs (cfg.symbolPreset != null) {inherit (cfg) symbolPreset;}
      // optionalAttrs (cfg.setupVersion != null) {inherit (cfg) setupVersion;}
      // optionalAttrs (theme != {}) {inherit theme;}
      // optionalAttrs (webSearchProvider != null) {providers.webSearch = webSearchProvider;}
      // optionalAttrs (modelRoles != {}) {inherit modelRoles;};
  in {
    assertions = [
      {
        assertion = !cfg.configureCodexModels || !codexEnabled || cfg.codexModel != null;
        message = "OMP configureCodexModels requires an explicit codexModel or the omp-workstation preset when Codex is enabled.";
      }
    ];
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
