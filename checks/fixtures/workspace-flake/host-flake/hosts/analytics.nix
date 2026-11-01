{
  system = "aarch64-linux";

  module = {hey, ...}: {
    imports = [
      hey.inputs.site.nixosModules.workspaceDefaults
    ];

    config = {...}: {
      home.stateVersion = "26.05";
      system.stateVersion = "26.05";
      user = {
        name = "analytics";
        home = "/home/analytics";
      };

      environment.variables.NIXI_WORKSPACE_HOST = "1";
    };
  };
}
