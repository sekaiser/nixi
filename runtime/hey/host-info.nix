{
  flakeRef,
  host,
  kind,
}: let
  flake = builtins.getFlake flakeRef;
  system = builtins.getAttr host flake.${kind};
  cfg = system.config;
  # Traverse option declarations, never arbitrary config values (which may
  # include credentials, package sets, or recursive user data).
  valueAt = path: builtins.foldl' (value: name: value.${name} or {}) cfg.modules path;
  enabledPaths = path: options:
    if !builtins.isAttrs options || (options._type or "") == "option"
    then []
    else
      (
        if options ? enable && ((valueAt path).enable or false) == true
        then [(builtins.concatStringsSep "." path)]
        else []
      )
      ++ builtins.concatMap
      (name: enabledPaths (path ++ [name]) options.${name})
      (builtins.attrNames options);
  journald = cfg.modules.services.journald or {};
  vm = cfg.modules.profiles.vm-image or {};
in {
  result = builtins.toJSON {
    system = system.pkgs.stdenv.hostPlatform.system;
    theme = cfg.modules.theme.active or "<unset>";
    profiles =
      builtins.intersectAttrs {
        user = null;
        role = null;
        platform = null;
        hardware = null;
        networks = null;
      }
      (cfg.modules.profiles or {})
      // builtins.listToAttrs (map (name: {
          inherit name;
          value.enable = true;
        })
        (map (path: builtins.substring (builtins.stringLength "profiles.") (-1) path)
          (enabledPaths ["profiles"] (system.options.modules.profiles or {}))));
    enabledModules = enabledPaths [] (removeAttrs (system.options.modules or {}) ["profiles" "theme"]);
    storage =
      if kind != "nixosConfigurations"
      then {}
      else {
        journald = {
          enable = journald.enable or false;
          systemMaxUse = journald.systemMaxUse or "";
          runtimeMaxUse = journald.runtimeMaxUse or "";
        };
        fstrim = cfg.services.fstrim.enable or false;
        noatime = builtins.elem "noatime" (cfg.fileSystems."/".options or []);
        vmImage = {
          enable = vm.enable or false;
          ssdOptimizations = vm.ssdOptimizations or false;
          autoCleanGenerations = vm.autoCleanGenerations or false;
          keepGenerations = vm.keepGenerations or 0;
        };
      };
  };
}
