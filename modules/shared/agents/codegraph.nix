{
  config,
  hey,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkIf optional;
  inherit (lib.types) bool listOf nullOr package str;
  inherit (hey.lib) mkBoolOpt' mkOpt';

  cfg = config.modules.agents.codegraph;
in {
  options.modules.agents.codegraph = {
    enable = mkBoolOpt' false "Whether to expose Codegraph as an agent harnessing/MCP tool.";
    package = mkOpt' (nullOr package) (pkgs.callPackage ../../../packages/codegraph.nix {}) "Optional Codegraph package to install. Set null when Codegraph is installed outside Nix.";
    command = mkOpt' str "codegraph" "Codegraph command name used by Codex MCP configuration.";
    args = mkOpt' (listOf str) ["serve" "--mcp"] "Codegraph MCP command arguments.";
    checkCommand = mkOpt' bool true "Whether `hey doctor agents` should require the Codegraph command on PATH.";
  };

  config = mkIf cfg.enable {
    user.packages = optional (cfg.package != null) cfg.package;

    hey.capabilities.agents.codegraph.commands =
      optional cfg.checkCommand cfg.command;
  };
}
