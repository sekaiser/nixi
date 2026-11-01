# Overlays

Overlays for both NixOS and nix-darwin.

Each `*.nix` file in this directory is loaded by `flake.nix` through
`lib.mapModules`. Do not add a `default.nix`; the flake maps overlay files
directly so each overlay has a stable attribute name.
