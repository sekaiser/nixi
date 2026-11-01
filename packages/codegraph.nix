{
  fetchurl,
  lib,
  stdenvNoCC,
  ...
}: let
  version = "1.6.0";
  sources = {
    aarch64-darwin = {
      asset = "codegraph-darwin-arm64";
      hash = "sha256-HHMDNRLVX2e+BHF+gVMui+r3vm+4Ux9RoXn6IwZK1IA=";
    };
    aarch64-linux = {
      asset = "codegraph-linux-arm64";
      hash = "sha256-bck1p7jxph5oileLmOo0aA6y4217kdsHnWT0AR8aZo8=";
    };
    x86_64-linux = {
      asset = "codegraph-linux-x64";
      hash = "sha256-3jOR957UJiLZN+bNW3ZCp+qLt9FHNgfoC4ebpz7yFrA=";
    };
  };
  source =
    sources.${stdenvNoCC.hostPlatform.system}
    or (throw "Codegraph is not packaged for ${stdenvNoCC.hostPlatform.system}");
in
  stdenvNoCC.mkDerivation {
    pname = "codegraph";
    inherit version;

    src = fetchurl {
      url = "https://github.com/colbymchenry/codegraph/releases/download/v${version}/${source.asset}.tar.gz";
      inherit (source) hash;
    };

    sourceRoot = source.asset;
    dontBuild = true;

    installPhase = ''
      runHook preInstall
      mkdir -p "$out"
      cp -R . "$out"
      runHook postInstall
    '';

    meta = {
      description = "Local semantic code intelligence MCP server";
      homepage = "https://github.com/colbymchenry/codegraph";
      license = lib.licenses.mit;
      mainProgram = "codegraph";
      platforms = lib.attrNames sources;
    };
  }
