{
  description = "Synthetic host metadata for CLI tests; not a deployable system";
  outputs = _: {
    darwinConfigurations.laptop = {
      pkgs.stdenv.hostPlatform.system = "aarch64-darwin";
      config.modules = {
        profiles.role = "workstation";
        profiles.workstation.enable = true;
        profiles.private = throw "must not serialize private profile settings";
        shell.tmux.enable = true;
        shell.zsh.enable = true;
      };
      options.modules.shell = {
        tmux.enable._type = "option";
        zsh.enable._type = "option";
      };
      options.modules.profiles = {
        workstation.enable._type = "option";
        private._type = "option";
      };
    };
    nixosConfigurations = {};
  };
}
