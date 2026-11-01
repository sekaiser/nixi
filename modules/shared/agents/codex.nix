{
  config,
  hey,
  lib,
  ...
}: let
  inherit (builtins) toJSON;
  inherit (lib) mkIf optional;
  inherit (lib.types) attrsOf either listOf nullOr package path str;
  inherit (hey.lib) mkBoolOpt' mkOpt';

  cfg = config.modules.agents.codex;
  paths = import ../../../lib/internal/file-contracts.nix {inherit lib;};
in {
  options.modules.agents.codex = {
    enable = mkBoolOpt' false "Whether to expose Codex metadata and opt-in skills without taking ownership of mutable authentication or configuration.";
    codexHome = mkOpt' str "${config.home.dir}/.codex" "Existing mutable Codex state directory; authentication and config files remain unmanaged by this module.";
    package = mkOpt' (nullOr package) null "Optional Codex package to install. Leave null when the platform installs Codex outside Nix, for example through Homebrew casks on Darwin.";
    commands = mkOpt' (listOf str) ["codex"] "Codex commands expected on PATH.";
    plugins = mkOpt' (listOf str) [] "Codex plugin entries explicitly expected in the existing Codex config.";
    mcpServers = mkOpt' (listOf str) [] "Codex MCP server entries explicitly expected in the existing Codex config. Enabling an agent does not imply an MCP integration.";
    skills = mkOpt' (attrsOf (either path package)) {} "Explicit skill-name to source-directory mapping. Each source must contain SKILL.md. Only these directories are managed; existing skills are preserved.";
    skillsDirectory = mkOpt' paths.runtimeSecretPath "${config.home.dir}/.agents/skills" "User skill discovery directory. Must remain inside the managed user's home; defaults to Codex's current user-scope location.";
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.all (name: builtins.match "[a-zA-Z0-9][a-zA-Z0-9._-]*" name != null) (builtins.attrNames cfg.skills);
        message = "Codex skill names must be safe single path components.";
      }
      {
        assertion = cfg.skills == {} || lib.hasPrefix "${config.home.dir}/" cfg.skillsDirectory;
        message = "Codex skill directories must be inside the managed user's home.";
      }
    ];
    home.file = lib.mapAttrs' (name: source:
      lib.nameValuePair "${cfg.skillsDirectory}/${name}" {inherit source;})
    cfg.skills;

    env.CODEX_HOME = cfg.codexHome;

    user.packages = optional (cfg.package != null) cfg.package;

    home.dataFile."hey/agents/codex.json" = {
      text = toJSON {
        inherit (cfg) codexHome plugins mcpServers;
      };
    };

    hey.capabilities.agents.codex = {
      commands = cfg.commands;
      directories."Codex state directory" = cfg.codexHome;
      files."Codex config file exists" = "${cfg.codexHome}/config.toml";
    };
  };
}
