{...}: {
  config = {pkgs, ...}: {
    home.stateVersion = "26.05";
    system.stateVersion = "26.05";
    user = {
      name = "host-flake-overlays";
      home = "/home/host-flake-overlays";
    };

    environment.variables.NIXI_OVERLAY_MARKER = pkgs.nixiOverlayMarker;
  };
}
