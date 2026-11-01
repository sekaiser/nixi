{hey, ...}: {
  imports = [
    hey.inputs.provider.nixosModules.reusable
  ];

  config = {...}: {
    home.stateVersion = "26.05";
    system.stateVersion = "26.05";
    user = {
      name = "module-output-consumer";
      home = "/home/module-output-consumer";
    };

    environment.variables.NIXI_MODULE_OUTPUTS_CONSUMER = "1";
  };
}
