{
  lib,
  stdenv,
  ...
}:
stdenv.mkDerivation {
  pname = "nixi-process-supervisor";
  version = "1";
  src = ../tools/process-supervisor;
  strictDeps = true;
  buildPhase = ''
    runHook preBuild
    $CC -std=c11 -O2 -Wall -Wextra -Werror main.c -o nixi-process-supervisor
    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
    install -Dm0755 nixi-process-supervisor "$out/bin/nixi-process-supervisor"
    runHook postInstall
  '';
  meta = {
    description = "Private process-group supervisor for Hey's noninteractive captures";
    mainProgram = "nixi-process-supervisor";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
    license = lib.licenses.mit;
  };
}
