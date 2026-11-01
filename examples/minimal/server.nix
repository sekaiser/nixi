_: {
  config = _: {
    user = {
      name = "alice";
      home = "/home/alice";
      isNormalUser = true;
    };
    system.stateVersion = "26.05";
    home.stateVersion = "26.05";
    networking.hostName = "server";
    hey.enable = true;
    # Add YOUR generated hardware configuration, filesystems and boot loader.
    # This file is an evaluation example, not a complete bootable installation.
  };
}
