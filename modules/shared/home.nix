# Home Manager integration with convenience aliases. Its standard user module
# API remains available for settings not represented by these aliases.
{
  hey,
  lib,
  config,
  options,
  pkgs,
  ...
}: let
  inherit (lib) concatStringsSep escapeShellArg mapAttrs' mapAttrsToList mkAliasDefinitions mkDefault nameValuePair optionalAttrs;
  inherit (lib.types) attrs str;
  inherit (hey.lib) mkOpt mkOpt';

  cfg = config.home;
  hm = config.home-manager.users.${config.user.name};
  pathOption = name:
    (mkOpt str hm.xdg.${name}) // {apply = _: hm.xdg.${name};};
  # Native Home Manager paths are authoritative. Forward only explicit legacy
  # definitions, retaining their priorities, so either API can override defaults.
  legacyPath = name:
    lib.mkIf (options.home.${name}.highestPrio < 1500)
    (lib.mkMerge (map (lib.mkOverride options.home.${name}.highestPrio)
        options.home.${name}.definitions));
in {
  imports = [
    hey.modules.home-manager.default
  ];

  # used by sops-nix and not available in nix-darwin
  options.systemd = {
    # user = mkOpt str "${config.user.name}";
    user.name = mkOpt str "${config.user.name}";
  };

  # used by sops-nix and not available in nix-darwin
  options.xdg = {
    configHome = mkOpt str "${cfg.configDir}";
  };

  options.home = {
    stateVersion = lib.mkOption {
      type = str;
      description = "Home Manager compatibility version chosen by the consumer. Do not advance it automatically on upgrades.";
    };
    file = mkOpt' attrs {} "Files to place directly in $HOME";
    configFile = mkOpt' attrs {} "Files to place in $XDG_CONFIG_HOME";
    dataFile = mkOpt' attrs {} "Files to place in $XDG_DATA_HOME";
    fakeFile = mkOpt' attrs {} "Files to place in $XDG_FAKE_HOME";

    dir = mkOpt str config.users.users.${config.user.name}.home;
    binDir = pathOption "binHome";
    cacheDir = pathOption "cacheHome";
    configDir = pathOption "configHome";
    runtimeDir = mkOpt str "${cfg.dir}/.local/runtime";
    dataDir = pathOption "dataHome";
    stateDir = pathOption "stateHome";
    fakeDir = mkOpt str "${cfg.dir}/.local/user";
  };

  config = {
    home.file =
      mapAttrs' (k: v: nameValuePair "${config.home.fakeDir}/${k}" v)
      config.home.fakeFile;

    # Install user packages to /etc/profiles instead. Necessary for
    # nixos-rebuild build-vm to work.
    home-manager = {
      useUserPackages = true;
      useGlobalPkgs = mkDefault true;

      users.${config.user.name} = {
        home = {
          file = mkAliasDefinitions options.home.file;
          stateVersion = mkDefault cfg.stateVersion;
          sessionVariables =
            lib.optionalAttrs (cfg.fakeFile != {}) {
              XDG_FAKE_HOME = cfg.fakeDir;
            }
            // optionalAttrs pkgs.stdenv.isDarwin {
              # On Linux PAM/systemd owns this per-session directory.
              XDG_RUNTIME_DIR = cfg.runtimeDir;
            };
        };
        xdg = {
          enable = mkDefault true;
          configFile = mkAliasDefinitions options.home.configFile;
          dataFile = mkAliasDefinitions options.home.dataFile;

          cacheHome = legacyPath "cacheDir";
          binHome = legacyPath "binDir";
          configHome = legacyPath "configDir";
          dataHome = legacyPath "dataDir";
          stateHome = legacyPath "stateDir";
        };
      };
    };
    environment.extraInit =
      ''
        # Nixi can manage shells without Home Manager's shell modules. Load only
        # the effective user's variables, never a primary user's global paths.
        case "$(${pkgs.coreutils}/bin/id -un)" in
          ${concatStringsSep "\n" (mapAttrsToList (name: user: ''
            ${escapeShellArg name}) . ${user.home.sessionVariablesPackage}/etc/profile.d/hm-session-vars.sh ;;
          '')
          config.home-manager.users)}
        esac
      ''
      + concatStringsSep "\n"
      (mapAttrsToList (n: v: "export ${n}=${escapeShellArg v}") config.env);
  };
}
