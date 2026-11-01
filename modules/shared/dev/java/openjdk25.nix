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
  options.modules.dev.java.openjdk25 = {
    enable = mkBoolOpt false;
  };

  config = let
    openjdk25 = pkgs.openjdk25;
  in
    mkIf cfg.openjdk25.enable {
      env.JAVA_HOME = "${openjdk25}";
      env.JDK_HOME = "${openjdk25}";

      modules.shell.zsh.rcFiles = ["${hey.assetsDir}/dev/java/aliases.zsh"];

      user.packages = [
        pkgs.checkstyle
        pkgs.gradle
        pkgs.jdt-language-server
        pkgs.maven
        openjdk25
      ];

      home.configFile = {
        "jdks" = {
          source = "${hey.assetsDir}/jdks";
          recursive = true;
        };
      };
    };
}
