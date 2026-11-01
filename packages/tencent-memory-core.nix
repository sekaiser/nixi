{
  buildNpmPackage,
  fetchFromGitHub,
  lib,
  makeWrapper,
  nodejs_24,
  ...
}:
buildNpmPackage {
  pname = "tencent-memory-core";
  version = "unstable-2026-10-13";
  src = fetchFromGitHub {
    owner = "TencentCloud";
    repo = "TencentDB-Agent-Memory";
    rev = "badbd2179d06f4e0e1f2133bd3482880beab8a02";
    hash = "sha256-fPaZpOyVrq8lao1vEXUoe31wHqxLvICnx6xPcVMPBXQ=";
  };
  sourceRoot = "source/MemoryCore";
  nodejs = nodejs_24;
  npmDepsHash = "sha256-27nrhbOkjUeuM3/4SvQdq63uYlmD6VenaLGxnECQ78Y=";
  # Upstream ships no dependency lock. Lock only the standalone runtime;
  # exclude development tools and optional OpenClaw/llama peer packages.
  postPatch = ''
    cp ${../assets/agent-memory/package.json} package.json
    cp ${../assets/agent-memory/package-lock.json} package-lock.json
  '';
  npmFlags = ["--ignore-scripts"];
  dontNpmBuild = true;
  nativeBuildInputs = [makeWrapper];
  installPhase = ''
    runHook preInstall
    mkdir -p "$out/lib/memory-core" "$out/bin"
    cp -R src node_modules package.json "$out/lib/memory-core/"
    cp ../LICENSE "$out/lib/memory-core/LICENSE"
    makeWrapper ${nodejs_24}/bin/node "$out/bin/tencent-memory-core" \
      --add-flags "--import $out/lib/memory-core/node_modules/tsx/dist/loader.mjs $out/lib/memory-core/src/gateway/server.ts"
    runHook postInstall
  '';
  meta = {
    description = "TencentDB Agent Memory standalone MemoryCore (no model proxy)";
    homepage = "https://github.com/TencentCloud/TencentDB-Agent-Memory";
    license = lib.licenses.mit;
    mainProgram = "tencent-memory-core";
    platforms = lib.platforms.unix;
  };
}
