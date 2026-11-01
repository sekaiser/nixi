{
  system = "aarch64-linux";

  module = {...}: {
    config = {...}: {
      home.stateVersion = "26.05";
      system.stateVersion = "26.05";
      user = {
        name = "analytics";
        home = "/home/analytics";
      };

      environment.variables.NIXI_DISCOVERED_ANALYTICS = "1";
    };
  };
}
