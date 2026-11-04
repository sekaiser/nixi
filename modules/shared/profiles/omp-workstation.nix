{
  config,
  lib,
  ...
}: let
  cfg = config.modules.agents.omp;
in {
  options.modules.profiles.omp-workstation.enable = lib.mkEnableOption "the opinionated OMP workstation settings";
  config = lib.mkIf config.modules.profiles.omp-workstation.enable (lib.mkMerge [
    {modules.agents.omp.enable = lib.mkDefault true;}
    (lib.mkIf cfg.enable {
      # Retain the former workflow only when explicitly selected. These are
      # compatibility choices, not current provider/model recommendations.
      modules.agents.omp = {
        manageConfig = lib.mkDefault true;
        configureCodexModels = lib.mkDefault true;
        codexModel = lib.mkDefault "openai-codex/gpt-5.5:medium";
        webSearchProvider = lib.mkDefault (
          if config.modules.agents.codex.enable
          then "codex"
          else null
        );
        symbolPreset = lib.mkDefault "unicode";
        setupVersion = lib.mkDefault 1;
        theme = lib.mapAttrs (_: lib.mkDefault) {
          dark = "titanium";
          light = "light";
        };
      };
    })
  ]);
}
