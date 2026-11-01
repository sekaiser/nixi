{hey, ...}: {
  imports = [
    hey.inputs.site.nixosModules.fixtureDefaults
  ];

  config = {...}: {
    home.stateVersion = "26.05";
    system.stateVersion = "26.05";
    user = {
      name = "fixture";
      home = "/home/fixture";
    };
    environment.variables.NIXI_FIXTURE_HOST = "1";
  };
}
