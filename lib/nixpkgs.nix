{...}: {
  # Package construction must not silently add image- or site-specific patches.
  mkPkgs = {
    system,
    pkgsSrc,
    overlays ? [],
    config ? {},
  }:
    import pkgsSrc {inherit system overlays config;};
}
