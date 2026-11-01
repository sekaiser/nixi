{
  system = "aarch64-linux";

  module = {...}: {
    config = {...}: {
      user = {
        name = "secret-provider";
        home = "/home/secret-provider";
      };
      system.stateVersion = "26.05";
      home.stateVersion = "26.05";

      modules.services = {
        k3s-agent = {
          enable = true;
          serverAddr = "https://k3s.example.invalid:6443";
          tokenFile = "/run/secrets/k3s-agent-token";
        };

        tailscale = {
          enable = true;
          keyFile = "/run/secrets/tailscale-auth-key";
        };
      };
    };
  };
}
