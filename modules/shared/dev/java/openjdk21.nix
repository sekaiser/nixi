{
  hey,
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkIf;
  inherit (hey.lib) mkBoolOpt;

  cfg = config.modules.dev.java;
in {
  options.modules.dev.java.openjdk21 = {
    enable = mkBoolOpt false;
  };

  config = let
    openjdk21 = pkgs.openjdk21;
  in
    mkIf cfg.openjdk21.enable {
      env.JAVA_HOME = "${openjdk21}";
      env.JDK_HOME = "${openjdk21}";

      modules.shell.zsh.rcFiles = ["${hey.assetsDir}/dev/java/aliases.zsh"];

      user.packages = [
        pkgs.checkstyle
        pkgs.gradle
        pkgs.jdt-language-server
        pkgs.maven
        openjdk21
      ];

      home.configFile = {
        "jdks" = {
          source = "${hey.assetsDir}/jdks";
          recursive = true;
        };
      };
    };
}
