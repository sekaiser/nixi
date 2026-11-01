{
  description = "Generic Darwin policy input fixture";

  outputs = inputs: {
    darwinModules.defaults = {...}: {
      environment.variables.NIXI_GENERIC_DARWIN_POLICY_INPUT = "1";
    };
  };
}
