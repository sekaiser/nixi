# Platform Modules

Platform modules implement operating-system backends.

- `darwin` is for nix-darwin/macOS behavior.
- `linux` is for NixOS behavior.

Do not put CPU-specific package choices here unless they are guarded by
`pkgs.stdenv.hostPlatform`. Prefer explicit host-local profiles for
architecture-specific behavior.
