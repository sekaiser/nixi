{
  rustPlatform,
  ...
}:
rustPlatform.buildRustPackage {
  pname = "tmux-status-check";
  version = "0.1.0";

  src = ../tools/tmux-status;

  cargoBuildFlags = ["--tests"];
  cargoLock.lockFile = ../tools/tmux-status/Cargo.lock;

  installPhase = ''
    runHook preInstall
    touch "$out"
    runHook postInstall
  '';
}
