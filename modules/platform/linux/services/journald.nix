{
  hey,
  lib,
  config,
  ...
}: let
  inherit (lib) mkIf types;
  inherit (hey.lib) mkBoolOpt' mkOpt';

  cfg = config.modules.services.journald;
in {
  options.modules.services.journald = {
    enable = mkBoolOpt' true "Whether to apply bounded systemd-journald storage defaults.";
    systemMaxUse = mkOpt' types.str "2G" "Maximum persistent journal disk usage.";
    runtimeMaxUse = mkOpt' types.str "256M" "Maximum runtime journal disk usage.";
  };

  config = mkIf cfg.enable {
    services.journald.extraConfig = ''
      SystemMaxUse=${cfg.systemMaxUse}
      RuntimeMaxUse=${cfg.runtimeMaxUse}
    '';
  };
}
