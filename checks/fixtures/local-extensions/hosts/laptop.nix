{
  system = "aarch64-linux";

  module = {...}: {
    imports = [
      ../profiles/workstation.nix
      ../modules/my-service.nix
    ];

    config = {...}: {
      home.stateVersion = "26.05";
      system.stateVersion = "26.05";
      user = {
        name = "local-extension";
        home = "/home/local-extension";
      };

      my.services.foo.enable = true;
      environment.variables.NIXI_LOCAL_HOST = "1";
    };
  };
}
