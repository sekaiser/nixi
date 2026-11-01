{...}: {
  config = {...}: {
    home.stateVersion = "26.05";
    system.stateVersion = "26.05";
    user = {
      name = "module-output-provider";
      home = "/home/module-output-provider";
    };

    environment.variables.NIXI_MODULE_OUTPUTS_PROVIDER = "1";
  };
}
