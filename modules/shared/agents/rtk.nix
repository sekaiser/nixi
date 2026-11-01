{
  config,
  hey,
  lib,
  ...
}: let
  inherit (lib) escapeShellArg mkIf optional;
  inherit (lib.types) bool nullOr package str;
  inherit (hey.lib) mkBoolOpt' mkOpt';

  cfg = config.modules.agents.rtk;
in {
  options.modules.agents.rtk = {
    enable = mkBoolOpt' false "Whether to expose RTK as an agent output-compression tool.";
    package = mkOpt' (nullOr package) null "Optional RTK package to install. Leave null when RTK is installed outside Nix, for example through Homebrew on Darwin.";
    command = mkOpt' str "rtk" "RTK command name expected on PATH.";
    checkCommand = mkOpt' bool true "Whether `hey doctor agents` should require the RTK command on PATH.";
    configureCodex = mkBoolOpt' true "Whether to configure RTK globally for Codex when the Codex module is enabled.";
    configureCopilot = mkBoolOpt' true "Whether to configure RTK globally for GitHub Copilot when the Copilot module is enabled.";
  };

  config = mkIf cfg.enable (let
    codexEnabled = config.modules.agents.codex.enable;
    copilotEnabled = config.modules.agents.copilot.enable;
    rtkCommand =
      if cfg.package != null
      then "${cfg.package}/bin/${cfg.command}"
      else cfg.command;
  in {
    user.packages = optional (cfg.package != null) cfg.package;

    hey.capabilities.agents.rtk.commands =
      optional cfg.checkCommand cfg.command;

    home-manager.users.${config.user.name}.home.activation = {
      configureRtkCodex =
        mkIf (cfg.configureCodex && codexEnabled)
        (config.home-manager.users.${config.user.name}.lib.dag.entryAfter ["writeBoundary"] ''
          if [[ -v DRY_RUN ]] || command -v ${escapeShellArg rtkCommand} >/dev/null 2>&1; then
            CODEX_HOME=${escapeShellArg config.modules.agents.codex.codexHome} run ${escapeShellArg rtkCommand} init -g --codex
          else
            echo "RTK Codex setup failed: ${rtkCommand} is not available" >&2
            exit 1
          fi
        '');

      configureRtkCopilot =
        mkIf (cfg.configureCopilot && copilotEnabled)
        (config.home-manager.users.${config.user.name}.lib.dag.entryAfter ["writeBoundary"] ''
          if [[ -v DRY_RUN ]] || command -v ${escapeShellArg rtkCommand} >/dev/null 2>&1; then
            run ${escapeShellArg rtkCommand} init -g --copilot
          else
            echo "RTK Copilot setup failed: ${rtkCommand} is not available" >&2
            exit 1
          fi
        '');
    };
  });
}
