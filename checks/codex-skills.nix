{
  nixi,
  lib,
  pkgs,
  runCommand,
  ...
}: let
  taste = pkgs.callPackage ../packages/taste-skill.nix {};
  humanizer = pkgs.callPackage ../packages/humanizer.nix {};
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
          modules.agents.codex = {
            enable = true;
            skills = {
              design-taste-frontend = taste;
              inherit humanizer;
            };
          };
        };
      };
    });
  };
  hosts = [outputs.darwinConfigurations.darwin outputs.nixosConfigurations.linux];
  checkHost = host: let
    cfg = host.config;
    files = cfg.home.file;
    disabled = (host.extendModules {modules = [{modules.agents.codex.enable = lib.mkForce false;}];}).config;
    empty = (host.extendModules {modules = [{modules.agents.codex.skills = lib.mkForce {};}];}).config;
    custom = (host.extendModules {modules = [{modules.agents.codex.skillsDirectory = "/fixture/alice/custom-skills";}];}).config;
    badName = (host.extendModules {modules = [{modules.agents.codex.skills."../escape" = taste;}];}).config;
    badDirectory = (host.extendModules {modules = [{modules.agents.codex.skillsDirectory = "/outside/skills";}];}).config;
  in
    toString files."/fixture/alice/.agents/skills/design-taste-frontend".source
    == toString taste
    && toString files."/fixture/alice/.agents/skills/humanizer".source == toString humanizer
    && !(files ? "/fixture/alice/.codex/config.toml")
    && !(files ? "/fixture/alice/.codex/auth.json")
    && !(disabled.home.file ? "/fixture/alice/.agents/skills/humanizer")
    && !(empty.home.file ? "/fixture/alice/.agents/skills/humanizer")
    && custom.home.file ? "/fixture/alice/custom-skills/humanizer"
    && lib.any (a: a.message == "Codex skill names must be safe single path components." && !a.assertion) badName.assertions
    && lib.any (a: a.message == "Codex skill directories must be inside the managed user's home." && !a.assertion) badDirectory.assertions;
in
  assert lib.all checkHost hosts;
    runCommand "codex-skills-check" {} ''
      test -f ${taste}/SKILL.md
      test -f ${taste}/LICENSE
      test -f ${humanizer}/SKILL.md
      test -f ${humanizer}/LICENSE
      test -f ${humanizer}/agents/openai.yaml
      grep -q '^name: design-taste-frontend$' ${taste}/SKILL.md
      grep -q '^name: humanizer$' ${humanizer}/SKILL.md
      touch "$out"
    ''
