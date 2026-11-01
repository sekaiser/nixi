{
  description = "External host shared policy fixture";

  outputs = inputs: {
    nixosModules.fixtureDefaults = {...}: {
      environment.variables.NIXI_EXTERNAL_SITE = "1";
    };
  };
}
