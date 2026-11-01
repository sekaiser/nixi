{hey, ...}: {
  imports = [
    hey.inputs.policy.nixosModules.defaults
  ];

  config = {...}: {
    home.stateVersion = "26.05";
    system.stateVersion = "26.05";
    user = {
      name = "generic-policy";
      home = "/home/generic-policy";
    };

    environment.variables.NIXI_GENERIC_POLICY_HOST = "1";
    environment.variables.NIXI_GENERIC_POLICY_MODULE_SET =
      if hey.modules ? policy
      then "1"
      else "0";
  };
}
