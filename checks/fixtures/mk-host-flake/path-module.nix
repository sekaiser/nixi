{...}: {
  config = {...}: {
    home.stateVersion = "26.05";
    system.stateVersion = "26.05";
    user = {
      name = "path-module-fixture";
      home = "/home/path-module-fixture";
    };
    environment.variables.NIXI_FIXTURE_PATH_MODULE_HOST = "1";
  };
}
