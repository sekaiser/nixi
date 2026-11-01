# Explicit provider adapter: no SOPS dependency or host inventory in the core.
{
  config,
  hey,
  lib,
  pkgs,
  ...
}: let
  provider = hey.inputs.sops-nix or (throw "nixi sops-darwin requires a consumer-supplied sops-nix input");
  providerModule = "${provider}/modules/nix-darwin";
  cfg = config.nixi.sopsDarwin;
  contracts = import ../../lib/internal/file-contracts.nix {inherit lib;};
  installer = pkgs.callPackage ../../packages/install-user-file.nix {};
  runtimePath = contracts.requireRuntimeSecretPath;
  locations = {
    "manifest.json" = "secrets";
    "manifest-for-users.json" = "secrets-for-users";
  };
  # Decorate only this provider's manifest builder, before upstream validation.
  # No source patching, import-from-derivation, global overlay or runtime JSON
  # rewriting. Upstream still owns decryption, RAM disks, rotation and launchd.
  protectedWriter = writeTextFile: args:
    if builtins.hasAttr args.name locations
    then let
      name = locations.${args.name};
      original = builtins.fromJSON (builtins.unsafeDiscardStringContext args.text);
      compatible = original.secretsMountPoint == "/run/${name}.d" && original.symlinkPath == "/run/${name}";
    in
      if !compatible
      then throw "nixi sops-darwin: upstream manifest layout changed; review the adapter before upgrading"
      else
        writeTextFile (args
          // {
            text = builtins.appendContext (builtins.toJSON (original
              // {
                secretsMountPoint = "${cfg.directory}/${name}.d";
                symlinkPath = "${cfg.directory}/${name}";
              })) (builtins.getContext args.text);
          })
    else writeTextFile args;
  # The two upstream child modules also construct manifests. Keep this package
  # view local to the provider's module subtree; preserve function arguments and
  # source locations for the Nix module system.
  adapt = source: let
    upstream = import source;
  in
    lib.setFunctionArgs (args: let
      module = upstream (args
        // {
          pkgs = args.pkgs // {writeTextFile = protectedWriter args.pkgs.writeTextFile;};
        });
    in
      module
      // {
        _file = toString source;
        imports = map (child:
          if builtins.isPath child && lib.hasPrefix "${providerModule}/" (toString child)
          then adapt child
          else child)
        (module.imports or []);
      })
    (builtins.functionArgs upstream);
  compatibleManifest = name: manifest: let
    document = builtins.fromJSON (builtins.unsafeDiscardStringContext manifest.text);
  in
    document.secretsMountPoint
    == "${cfg.directory}/${name}.d"
    && document.symlinkPath == "${cfg.directory}/${name}";
in {
  _class = "darwin";
  disabledModules = [providerModule];
  imports = [(adapt providerModule)];

  options = {
    nixi.sopsDarwin.directory = lib.mkOption {
      type = lib.types.str;
      default = "/private/var/lib/nixi-sops";
      description = "Dedicated protected parent for SOPS RAM-backed mounts and generation links. Existing directories must be root-owned and not group/world writable; symlink ancestors are refused.";
    };
    # Nix path values are copied into the store when serialized into manifests.
    sops.age.keyFile = lib.mkOption {apply = runtimePath;};
    sops.age.sshKeyPaths = lib.mkOption {apply = map runtimePath;};
    sops.gnupg.home = lib.mkOption {apply = runtimePath;};
    sops.gnupg.sshKeyPaths = lib.mkOption {apply = map runtimePath;};
    sops.secrets = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule ({config, ...}: {
        config.path = lib.mkDefault "${cfg.directory}/${
          if config.neededForUsers
          then "secrets-for-users"
          else "secrets"
        }/${config.name}";
      }));
    };
    sops.templates = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule ({config, ...}: {
        config.path = lib.mkDefault "${cfg.directory}/secrets/rendered/${config.name}";
      }));
    };
    sops.package = lib.mkOption {
      # Preserve native package overrides. Validation is read-only and must not
      # try to prepare host directories in a build sandbox.
      apply = package:
        pkgs.writeShellScriptBin "sops-install-secrets" ''
          set -eu
          case "''${1-}" in
            -check-mode=manifest|-check-mode=sopsfile)
              exec ${package}/bin/sops-install-secrets "$@"
              ;;
          esac
          ${installer}/bin/nixi-install-user-file --prepare-source-directory ${lib.escapeShellArg "${cfg.directory}/secrets.d"}
          ${installer}/bin/nixi-install-user-file --prepare-source-directory ${lib.escapeShellArg "${cfg.directory}/secrets-for-users.d"}
          exec ${package}/bin/sops-install-secrets "$@"
        '';
    };
  };

  config.assertions = [
    {
      assertion = contracts.absolute cfg.directory && lib.hasPrefix "/private/var/lib/" cfg.directory;
      message = "nixi.sopsDarwin.directory must name a dedicated canonical directory below /private/var/lib/.";
    }
    {
      assertion =
        (config.sops.secrets == {} || compatibleManifest "secrets" config.system.build.sops-nix-manifest)
        && compatibleManifest "secrets-for-users" config.system.build.sops-nix-users-manifest;
      message = "nixi sops-darwin: upstream manifest construction changed; review the adapter before activating.";
    }
  ];
}
