# Explicit opt-in: disk layout and image policy remain in the host module.
{hey, ...}: {
  _class = "nixos";
  imports = [
    (hey.inputs.disko.nixosModules.disko
      or (throw "nixi Disko module requires a disko input exposing nixosModules.disko"))
  ];
}
