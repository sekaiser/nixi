{
  nixi,
  lib,
  callPackage,
  python3,
  runCommand,
  ...
}: let
  installer = callPackage ../packages/install-user-file.nix {};
  outputs = nixi.lib.mkHostFlake {
    inputs = {
      self.outPath = ./fixtures/cli-host;
      inherit nixi;
    };
    hosts = lib.genAttrs ["linux" "arm" "darwin"] (name: {
      system =
        if name == "darwin"
        then "aarch64-darwin"
        else if name == "arm"
        then "aarch64-linux"
        else "x86_64-linux";
      module = _: {
        config = {
          user = {
            name = "alice";
            home = "/fixture/alice";
          };
          home.stateVersion = "26.05";
          system.stateVersion =
            if name == "darwin"
            then 6
            else "26.05";
        };
      };
    });
  };
  hosts = [outputs.nixosConfigurations.linux outputs.nixosConfigurations.arm outputs.darwinConfigurations.darwin];
  checkHost = host: let
    extend = module: (host.extendModules {modules = [module];}).config;
    declared = {
      modules.shell.git = {
        enable = true;
        secrets.fixture.sourceFile = "/run/secrets/synthetic";
      };
    };
    neutral = extend declared;
    tracked = extend {
      imports = [declared];
      modules.shell.git.secretTracking.enable = true;
    };
    removed = extend {
      modules.shell.git = {
        enable = true;
        secretTracking.enable = true;
      };
    };
    disabled = extend {
      modules.shell.git = {
        enable = false;
        secretTracking.enable = true;
      };
    };
    foreign = extend {
      imports = [declared];
      modules.shell.git.secretTracking = {
        enable = true;
        receiptDirectory = "/fixture/other/receipts";
      };
    };
    collision = extend {
      imports = [declared];
      modules.shell.git.secretTracking = {
        enable = true;
        receiptDirectory = "/fixture/alice/.config/git/config/receipts";
      };
    };
    activation = cfg: cfg.system.activationScripts.postActivation.text or "";
    noRetirement = cfg: lib.all (flag: !lib.hasInfix flag (activation cfg)) ["--retire-receipt" "--restore-retirement" "--preview-retirement"];
    blocked = cfg: lib.any (a: !a.assertion && lib.hasPrefix "Git secret tracking receipts" a.message) cfg.assertions;
  in
    !neutral.modules.shell.git.secretTracking.enable
    && !lib.hasInfix "--receipt" (activation neutral)
    && lib.hasInfix "--receipt" (activation tracked)
    && lib.hasInfix "${builtins.hashString "sha256" "fixture"}.json" (activation tracked)
    && tracked.modules.shell.git.secretTracking.receiptDirectory == "/fixture/alice/.local/state/nixi/git-secret-copies"
    && lib.any (pkg: lib.getName pkg == "nixi-install-user-file") tracked.users.users.alice.packages
    && !lib.hasInfix "nixi-install-user-file" (activation removed)
    && !lib.hasInfix "--receipt" (activation disabled)
    && lib.all noRetirement [neutral tracked removed disabled]
    && blocked foreign
    && blocked collision;
in
  assert lib.assertMsg (lib.all checkHost hosts) "Git tracked-copy policy matrix failed";
    runCommand "user-file-installation-check" {
      src = ../.;
      nativeBuildInputs = [python3];
    } ''
      export PYTHONDONTWRITEBYTECODE=1
      export NIXI_TEST_INSTALLER=${installer}/bin/nixi-install-user-file
      python "$src/test_tools/test_install_user_file.py"
      python "$src/test_tools/test_tracked_user_file.py"
      touch "$out"
    ''
