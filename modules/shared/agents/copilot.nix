{
  config,
  hey,
  lib,
  ...
}: let
  inherit (lib) mkIf optional;
  inherit (lib.types) bool nullOr package str;
  inherit (hey.lib) mkBoolOpt' mkOpt';

  cfg = config.modules.agents.copilot;
in {
  options.modules.agents.copilot = {
    enable = mkBoolOpt' false "Whether to expose GitHub Copilot CLI as an agent.";
    package = mkOpt' (nullOr package) null "Optional GitHub Copilot CLI package to install. Leave null when installed outside Nix, for example through Homebrew on Darwin.";
    command = mkOpt' str "copilot" "GitHub Copilot CLI command name expected on PATH.";
    checkCommand = mkOpt' bool true "Whether `hey doctor agents` should require the Copilot command on PATH.";
  };

  config = mkIf cfg.enable {
    user.packages = optional (cfg.package != null) cfg.package;

    hey.capabilities.agents.copilot.commands =
      optional cfg.checkCommand cfg.command;
  };
}
