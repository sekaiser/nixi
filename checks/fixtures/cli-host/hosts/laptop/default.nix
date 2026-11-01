_: {
  system = "aarch64-darwin";
  module = _: {
    modules = {
      profiles.primary-user = {};
      shell.tmux.enable = true;
      shell.zsh.enable = true;
    };
  };
}
