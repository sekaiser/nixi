{
  system = "x86_64-linux";

  module = {...}: {
    config = {...}: {
      home.stateVersion = "26.05";
      system.stateVersion = "26.05";
      user = {
        name = "worker";
        home = "/home/worker";
      };

      environment.variables.NIXI_DISCOVERED_WORKER = "1";
    };
  };
}
