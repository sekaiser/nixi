{
  fetchFromGitHub,
  lib,
  stdenvNoCC,
  ...
}:
stdenvNoCC.mkDerivation {
  pname = "humanizer";
  version = "3.1.0";
  src = fetchFromGitHub {
    owner = "blader";
    repo = "humanizer";
    rev = "225a6f39ac85f76ee48dbad772ea4abe4ed6c9d8";
    hash = "sha256-n8cbTzhlGf8VnWpPukq7XD2mucIrqyE1XMpAAc5oA8A=";
  };
  dontBuild = true;
  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    cp SKILL.md LICENSE "$out/"
    cp -R agents "$out/agents"
    runHook postInstall
  '';
  meta = {
    description = "Humanizer prose editing skill";
    homepage = "https://github.com/blader/humanizer";
    license = lib.licenses.mit;
    platforms = lib.platforms.all;
  };
}
