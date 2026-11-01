_: {
  config = _: {
    user = {
      name = "alice";
      home = "/Users/alice";
    };
    system.primaryUser = "alice";
    system.stateVersion = 6;
    home.stateVersion = "26.05";
    networking.hostName = "laptop";
    hey.enable = true;
    # Opt into editor/shell modules here. Nothing from a maintainer host is used.
  };
}
