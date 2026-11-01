{hey, ...}: {
  imports = [
    hey.inputs.site.nixosModules.fixtureDefaults
  ];

  config = {...}: {
    home.stateVersion = "26.05";
    system.stateVersion = "26.05";
    user = {
      name = "external-fixture";
      home = "/home/external-fixture";
    };

    environment.variables.NIXI_EXTERNAL_HOST = "1";
    environment.variables.NIXI_EXTERNAL_WORKSPACE = hey.dir;
    environment.variables.NIXI_EXTERNAL_FRAMEWORK = hey.frameworkDir;
    environment.variables.NIXI_EXTERNAL_CONTEXT_HAS_PATH =
      if hey.args ? path
      then "1"
      else "0";
  };
}
