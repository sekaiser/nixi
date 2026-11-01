{...}: {
  config = {...}: {
    home.stateVersion = "26.05";
    system.stateVersion = "26.05";
    user = {
      name = "root-fixture";
      home = "/home/root-fixture";
    };

    environment.variables.NIXI_ROOT_HOST = "1";
  };
}
