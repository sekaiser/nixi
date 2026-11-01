{
  hey,
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkDefault mkIf;
  inherit (hey.lib) mkBoolOpt mkOpt;

  cfg = config.modules.shell.gnupg;
in {
  options.modules.shell.gnupg = {
    enable = mkBoolOpt false;
    cacheTTL = mkOpt lib.types.ints.positive 3600; # 1hr
    pinentryPackage = lib.mkOption {
      type = lib.types.package;
      default =
        if pkgs.stdenv.isDarwin
        then pkgs.pinentry_mac
        else pkgs.pinentry-curses;
      defaultText = lib.literalExpression "if pkgs.stdenv.isDarwin then pkgs.pinentry_mac else pkgs.pinentry-curses";
      description = "Nix-managed pinentry interface. Native Home Manager settings may override this default.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = !config.programs.gnupg.agent.enable;
        message = "modules.shell.gnupg uses Home Manager's per-user agent; disable programs.gnupg.agent.enable to avoid competing agents.";
      }
    ];
    home-manager.users.${config.user.name} = {
      config,
      lib,
      ...
    }: {
      programs.gpg = {
        enable = mkDefault true;
        homedir = mkDefault "${config.xdg.configHome}/gnupg";
      };
      services.gpg-agent = {
        enable = mkDefault true;
        defaultCacheTtl = mkDefault cfg.cacheTTL;
        pinentry.package = mkDefault cfg.pinentryPackage;
      };
      # Run as the HM user, after directory creation and before links are installed.
      # Tighten only the directory itself; never recurse through keyrings or links.
      home.activation.secureGpgHomedir = lib.mkIf config.programs.gpg.enable (lib.hm.dag.entryBetween ["linkGeneration"] ["createGpgHomedir"] ''
        if [ -L ${lib.escapeShellArg config.programs.gpg.homedir} ]; then
          echo "Refusing to change permissions on a symlinked GnuPG home" >&2
          exit 1
        fi
        run ${pkgs.coreutils}/bin/chmod 0700 -- ${lib.escapeShellArg config.programs.gpg.homedir}
      '');
    };
    # Nixi's shell modules do not require HM's shell integrations to be enabled.
    environment.interactiveShellInit = ''
      if [ "$(${pkgs.coreutils}/bin/id -un)" = ${lib.escapeShellArg config.user.name} ]; then
        export GPG_TTY="$(tty)"
      fi
    '';
  };
}
