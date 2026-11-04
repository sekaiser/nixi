{
  config,
  hey,
  lib,
  pkgs,
  ...
}: {
  options.modules.profiles.java-workstation.enable = lib.mkEnableOption "Java workstation tools and user-session preferences";
  config = lib.mkIf config.modules.profiles.java-workstation.enable (lib.mkMerge [
    {modules.dev.java.enable = lib.mkDefault true;}
    (lib.mkIf config.modules.dev.java.enable {
      user.packages = with pkgs; [checkstyle gradle jdt-language-server maven];
      home-manager.users.${config.user.name}.home.sessionVariables = {
        JAVA_HOME = lib.mkDefault (toString config.modules.dev.java.package);
        JDK_HOME = lib.mkDefault (toString config.modules.dev.java.package);
      };
      modules.shell.zsh.rcFiles = lib.mkIf config.modules.shell.zsh.enable ["${hey.assetsDir}/dev/java/aliases.zsh"];
    })
  ]);
}
