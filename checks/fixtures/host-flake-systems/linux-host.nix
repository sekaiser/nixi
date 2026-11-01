{...}: {
  config = {...}: {
    home.stateVersion = "26.05";
    system.stateVersion = "26.05";
    user = {
      name = "host-flake-systems";
      home = "/home/host-flake-systems";
    };

    environment.variables.NIXI_HOST_FLAKE_SYSTEMS = "1";
  };
}
