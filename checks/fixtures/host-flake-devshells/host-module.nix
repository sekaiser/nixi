{hey, ...}: {
  config = {...}: {
    home.stateVersion = "26.05";
    system.stateVersion = "26.05";
    user = {
      name = "host-flake-devshells";
      home = "/home/host-flake-devshells";
    };

    environment.variables.NIXI_DEVSHELL_MARKER = hey.devShell.marker.name;
  };
}
