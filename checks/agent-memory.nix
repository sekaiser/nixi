{
  nixi,
  lib,
  python3,
  callPackage,
  runCommand,
  ...
}: let
  core = callPackage ../packages/tencent-memory-core.nix {};
  outputs = nixi.lib.mkHostFlake {
    inputs = {
      self.outPath = ./fixtures/cli-host;
      inherit nixi;
    };
    hosts = lib.genAttrs ["darwin" "linux"] (platform: {
      system =
        if platform == "darwin"
        then "aarch64-darwin"
        else "x86_64-linux";
      module = _: {
        config = {
          user = {
            name = "alice";
            home = "/fixture/alice";
          };
          home.stateVersion = "26.05";
          system.stateVersion =
            if platform == "darwin"
            then 6
            else "26.05";
          modules.agents = {
            codex.enable = true;
            memory.enable = true;
          };
        };
      };
    });
  };
  darwin = outputs.darwinConfigurations.darwin;
  linux = outputs.nixosConfigurations.linux;
  d = darwin.config.home-manager.users.alice;
  l = linux.config.home-manager.users.alice;
  disabled = (darwin.extendModules {modules = [{modules.agents.memory.enable = lib.mkForce false;}];}).config.home-manager.users.alice;
  noCodex = (darwin.extendModules {modules = [{modules.agents.codex.enable = lib.mkForce false;}];}).config.home-manager.users.alice;
in
  assert d.launchd.agents.nixi-agent-memory.config.Umask == 63;
  assert d.launchd.agents.nixi-agent-memory.config.RunAtLoad;
  assert l.systemd.user.services.nixi-agent-memory.Service.UMask == "0077";
  assert !(disabled.launchd.agents ? nixi-agent-memory);
  assert !(noCodex.home.activation ? configureTencentMemory);
  assert lib.hasInfix "register" d.home.activation.configureTencentMemory.data;
    runCommand "agent-memory-check" {
      src = ../.;
      nativeBuildInputs = [python3];
    } ''
      export PYTHONDONTWRITEBYTECODE=1
      # Nix's Darwin sandbox forbids even loopback listeners. Keep the native
      # check offline; run the opt-in real Core test separately outside it.
      python "$src/test_tools/test_agent_memory.py"
      # Data URLs need no listener; native CI must also gate the bundled fetch.
      ${core.nodejs}/bin/node "$src/test_tools/probe_memory_http.mjs" \
        --require-bundled ${core}
      touch "$out"
    ''
