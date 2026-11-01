{hey, ...}: {
  config = {...}: {
    home.stateVersion = "26.05";
    system.stateVersion = "26.05";
    user = {
      name = "host-flake-apps";
      home = "/home/host-flake-apps";
    };

    environment.variables.NIXI_APP_MARKER = hey.apps.marker.program;
  };
}
