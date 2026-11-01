{
  system = "aarch64-linux";

  module = {...}: {
    config = {...}: {
      home.stateVersion = "26.05";
      system.stateVersion = "26.05";
      user = {
        name = "path-fixture";
        home = "/home/path-fixture";
      };
      environment.variables.NIXI_FIXTURE_PATH_HOST = "1";
    };
  };
}
