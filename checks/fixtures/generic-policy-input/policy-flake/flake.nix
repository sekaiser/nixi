{
  description = "Generic policy input fixture";

  outputs = inputs: {
    nixosModules.defaults = {...}: {
      environment.variables.NIXI_GENERIC_POLICY_INPUT = "1";
    };
  };
}
