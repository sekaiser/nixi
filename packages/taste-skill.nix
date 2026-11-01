{
  fetchFromGitHub,
  lib,
  stdenvNoCC,
  ...
}:
stdenvNoCC.mkDerivation {
  pname = "taste-skill";
  version = "unstable-2026-10-13";
  src = fetchFromGitHub {
    owner = "Leonxlnx";
    repo = "taste-skill";
    rev = "d237dd399d57524945c0c81327da5da19f7a468d";
    hash = "sha256-fjmfD27IaLIQZM6lp6Jmo1pZcA19nTgGXQzT5D9wTeE=";
  };
  dontBuild = true;
  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    cp -R skills/taste-skill/. "$out/"
    cp LICENSE "$out/LICENSE"
    runHook postInstall
  '';
  meta = {
    description = "Taste frontend design skill (design-taste-frontend)";
    homepage = "https://github.com/Leonxlnx/taste-skill";
    license = lib.licenses.mit;
    platforms = lib.platforms.all;
  };
}
