{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.modules.dev.java;
in {
  options.modules.dev.java = {
    enable =
      (lib.mkEnableOption "the selected Java runtime")
      // {
        default = cfg.openjdk21.enable || cfg.openjdk25.enable;
        defaultText = lib.literalExpression "openjdk21.enable || openjdk25.enable";
      };
    package = lib.mkOption {
      type = lib.types.package;
      default =
        if cfg.openjdk21.enable
        then pkgs.openjdk21
        else if cfg.openjdk25.enable
        then pkgs.openjdk25
        else pkgs.jdk;
      defaultText = lib.literalExpression "the legacy-selected JDK, otherwise pkgs.jdk";
      description = "The single Java runtime/JDK added to the selected user's packages. Build tools, Java home variables and shell preferences are supplied by the explicit java-workstation preset or consumer policy.";
    };
    openjdk21.enable = lib.mkEnableOption "the compatibility selector for JDK 21";
    openjdk25.enable = lib.mkEnableOption "the compatibility selector for JDK 25";
  };
  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = !cfg.enable || !(cfg.openjdk21.enable && cfg.openjdk25.enable);
          message = "Enable only one legacy Java selector; use modules.dev.java.package for an explicit primary runtime.";
        }
      ];
    }
    (lib.mkIf cfg.enable {user.packages = [cfg.package];})
  ];
}
