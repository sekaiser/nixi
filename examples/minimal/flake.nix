{
  description = "Synthetic Nixi consumer example; customize before activation";
  # Replace the placeholder after publication; see the local override in the guide.
  inputs.nixi.url = "github:YOUR-ORG/nixi";

  outputs = inputs:
    inputs.nixi.lib.mkHostFlake {
      inherit inputs;
      hosts = {
        laptop = {
          system = "aarch64-darwin";
          module = ./laptop.nix;
        };
        server = {
          system = "x86_64-linux";
          module = ./server.nix;
        };
      };
    };
}
