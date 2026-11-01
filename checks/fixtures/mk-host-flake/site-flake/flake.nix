{
  description = "mkHostFlake shared policy fixture";

  outputs = inputs: {
    nixosModules.fixtureDefaults = {...}: {
      environment.variables.NIXI_FIXTURE_SITE = "1";
    };
  };
}
