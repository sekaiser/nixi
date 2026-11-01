{
  lib,
  config,
  ...
}: let
  inherit (lib) any attrValues elem mkDefault mkIf;
  hasZfs = any (x: x ? fsType && x.fsType == "zfs") (attrValues config.fileSystems);
in
  mkIf (elem "ssd" config.modules.profiles.hardware) {
    services = {
      fstrim.enable = mkDefault (!hasZfs);
      zfs.trim.enable = mkDefault hasZfs;
    };
    boot.initrd.availableKernelModules = ["nvme"];
  }
