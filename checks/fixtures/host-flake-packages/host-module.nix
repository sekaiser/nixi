{hey, ...}: {
  config = {...}: {
    home.stateVersion = "26.05";
    system.stateVersion = "26.05";
    user = {
      name = "host-flake-packages";
      home = "/home/host-flake-packages";
    };

    environment.variables.NIXI_PACKAGE_MARKER = hey.packages.marker.name;
  };
}
