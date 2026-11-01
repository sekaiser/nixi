{hey, ...}: {
  imports = [
    hey.inputs.policy.darwinModules.defaults
  ];

  config = {...}: {
    home.stateVersion = "26.05";
    user = {
      name = "generic-darwin-policy";
      home = "/Users/generic-darwin-policy";
    };

    environment.variables.NIXI_GENERIC_DARWIN_POLICY_HOST = "1";
    environment.variables.NIXI_GENERIC_DARWIN_POLICY_MODULE_SET =
      if hey.modules ? policy
      then "1"
      else "0";
  };
}
