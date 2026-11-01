{
  rustPlatform,
  ...
}:
rustPlatform.buildRustPackage {
  pname = "hey-tmux-status";
  version = "0.1.0";

  src = ../tools/tmux-status;

  cargoLock.lockFile = ../tools/tmux-status/Cargo.lock;
}
