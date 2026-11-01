{lib, ...}: let
  inherit (builtins) isAttrs isFunction;
  inherit (lib) assertMsg concatStringsSep elem;
in rec {
  validSystems = [
    "aarch64-darwin"
    "aarch64-linux"
    "x86_64-linux"
  ];

  validTargets = [
    "runtime"
    "qcow-efi"
  ];

  importHostDescriptor = path: let
    imported = import path;
  in
    if isFunction imported
    then imported {}
    else imported;

  normalizeHostDescriptor = hostName: descriptor: let
    source = descriptor.path or "<unknown>";
    config = descriptor.config or {};
    target = config.target or "runtime";
    hostLabel = "${hostName} (${source})";
  in
    assert assertMsg (isAttrs descriptor)
    "Host ${hostName} descriptor must be an attribute set.";
    assert assertMsg (descriptor ? path)
    "Host ${hostName} descriptor must include a path.";
    assert assertMsg (descriptor ? config)
    "Host ${hostLabel} must define config.";
    assert assertMsg (isAttrs config)
    "Host ${hostLabel} config must be an attribute set.";
    assert assertMsg (config ? system)
    "Host ${hostLabel} must define a system.";
    assert assertMsg (elem config.system validSystems)
    "Host ${hostLabel} has unsupported system '${config.system}'. Expected one of: ${concatStringsSep ", " validSystems}";
    assert assertMsg (elem target validTargets)
    "Host ${hostLabel} has unsupported target '${target}'. Expected one of: ${concatStringsSep ", " validTargets}";
    assert assertMsg (config ? module)
    "Host ${hostLabel} must define a module function.";
    assert assertMsg (isFunction config.module)
    "Host ${hostLabel} module must be a function.";
    assert assertMsg (target != "qcow-efi" || lib.hasSuffix "-linux" config.system)
    "Host ${hostLabel}: the legacy qcow-efi target requires Linux.";
      descriptor
      // {
        config =
          config
          // {
            inherit target;
            # Compatibility at the descriptor boundary, not image policy in
            # the host builder. New hosts can import nixosModules.disko directly.
            module =
              if target == "qcow-efi"
              then
                args: let
                  host = config.module args;
                in
                  host // {imports = (host.imports or []) ++ [../modules/optional/disko.nix];}
              else config.module;
          };
      };
}
