{
  nixi,
  lib,
  runCommand,
  writeText,
  coreutils,
  ...
}: let
  outputs = nixi.lib.mkHostFlake {
    inputs = {
      self.outPath = ./fixtures/cli-host;
      inherit nixi;
    };
    hosts.laptop = {
      system = "aarch64-darwin";
      module = _: {
        config = {
          user = {
            name = "alice";
            home = "/Users/alice";
          };
          home.stateVersion = "26.05";
          system.stateVersion = 6;
        };
      };
    };
  };
  host = outputs.darwinConfigurations.laptop;
  extend = module: (host.extendModules {modules = [module];}).config;
  untouched = extend {modules.desktop.dock.enable = true;};
  empty = extend {
    modules.desktop.dock = {
      enable = true;
      entries = [];
    };
  };
  populated = extend {
    modules.desktop.dock = {
      enable = true;
      entries = [
        {path = "/Applications/Example App.app";}
        {
          path = "/Users/alice/Downloads";
          section = "others";
        }
      ];
    };
  };
  invalid = extend {
    modules.desktop.dock = {
      enable = true;
      entries = [
        {
          path = "/Applications/Example.app";
          options = ["--label" "ignored"];
        }
      ];
    };
  };
  neutralZed = extend {modules.editors.zed.enable = true;};
  terminalPreset = extend {modules.profiles.alacritty-workstation.enable = true;};
  disabledTerminalPreset = extend {
    modules.profiles.alacritty-workstation.enable = true;
    modules.shell.alacritty.enable = false;
  };
  terminalSettings = builtins.fromTOML (builtins.unsafeDiscardStringContext terminalPreset.home.configFile."alacritty/alacritty.toml".text);
  doomPreset = extend {modules.profiles.doom-workstation.enable = true;};
  preset = extend {
    modules.profiles.zed-workstation.enable = true;
    modules.editors.zed.settings = {
      ui_font_size = 14;
      theme.dark = "Custom";
    };
  };
  disabledPreset = extend {
    modules.profiles.zed-workstation.enable = true;
    modules.editors.zed.enable = false;
  };
  activation = config: writeText "dock-activation" (builtins.unsafeDiscardStringContext config.system.activationScripts.userDefaults.text);
  docker = extend {modules.services.docker.enable = true;};
  customDocker = extend {
    modules.services.docker = {
      enable = true;
      colimaHome = "/fixture/colima home";
    };
    home-manager.users.alice.home.sessionVariables.DOCKER_CONTEXT = "consumer-context";
  };
  invalidDocker = extend {
    modules.services.docker = {
      enable = true;
      colimaHome = "relative";
    };
  };
  dockerHome = docker.home-manager.users.alice.home;
  customDockerHome = customDocker.home-manager.users.alice.home;
  colimaActivation = writeText "colima-activation-fixture" (builtins.replaceStrings
    ["'/fixture/colima home'" "${host.pkgs.coreutils}/bin/mkdir"]
    [''"$colima_fixture"'' "${coreutils}/bin/mkdir"]
    (builtins.unsafeDiscardStringContext customDockerHome.activation.createColimaHome.data));
in
  assert terminalSettings.window.startup_mode == "Fullscreen";
  assert !(disabledTerminalPreset.home.configFile ? "alacritty/alacritty.toml");
  assert lib.hasInfix "NSWindowTabbingEnabled" terminalPreset.system.activationScripts.postActivation.text;
  assert !(lib.hasInfix "NSWindowTabbingEnabled" disabledTerminalPreset.system.activationScripts.postActivation.text);
  assert terminalSettings.env.TERM == "alacritty";
  assert (builtins.head terminalSettings.hints.enabled).command == "open";
  assert lib.hasSuffix "/assets/doom" (toString doomPreset.modules.editors.emacs.doomDir);
  assert !(docker.modules.services.docker ? cacheTTL);
  assert lib.all (name: !(dockerHome.sessionVariables ? ${name})) ["COLIMAHOME" "COLIMA_HOME" "DOCKER_HOST" "DOCKER_CONTEXT"];
  assert !(dockerHome.activation ? createColimaHome);
  assert customDockerHome.sessionVariables.COLIMA_HOME == "/fixture/colima home";
  assert customDockerHome.sessionVariables.DOCKER_CONTEXT == "consumer-context";
  assert !(customDockerHome.sessionVariables ? DOCKER_HOST);
  assert lib.any (a: !a.assertion && lib.hasInfix "colimaHome" a.message) invalidDocker.assertions;
  assert docker.home.configFile."docker/cli-plugins/docker-compose".source == "${host.pkgs.docker-compose}/bin/docker-compose";
  assert docker.home.configFile."docker/cli-plugins/docker-buildx".source == "${host.pkgs.docker-buildx}/bin/docker-buildx";
  assert untouched.system.defaults.dock.persistent-apps == null;
  assert untouched.system.defaults.dock.persistent-others == null;
  assert empty.system.defaults.dock.persistent-apps == [];
  assert empty.system.defaults.dock.persistent-others == [];
  assert (builtins.head populated.system.defaults.dock.persistent-apps).tile-data.file-data._CFURLString == "/Applications/Example App.app";
  assert lib.any (assertion: !assertion.assertion) invalid.assertions;
  assert neutralZed.modules.editors.zed.settings == {};
  assert neutralZed.modules.editors.zed.tasks == [];
  assert neutralZed.modules.editors.zed.extensions == [];
  assert neutralZed.home.dataFile ? "hey/zed-extensions.json";
  assert !(disabledPreset.home.dataFile ? "hey/zed-extensions.json");
  assert preset.modules.editors.zed.enable;
  assert preset.modules.editors.zed.settings.ui_font_size == 14;
  assert preset.modules.editors.zed.settings.theme.dark == "Custom";
  assert !(preset.modules.editors.zed.settings ? agent_servers);
  assert lib.elem "nix" preset.modules.editors.zed.extensions;
    runCommand "desktop-policy-check" {} ''
      # Exercise native activation commands without touching macOS preferences.
      id() { printf 1000; }
      launchctl() { printf '%s\n' "$*" >> "$activation_log"; }
      killall() { :; }
      activation_log="$TMPDIR/dock-commands"
      touch "$activation_log"
      source ${activation host.config}
      source ${activation untouched}
      test ! -s "$activation_log"
      source ${activation populated}
      grep -q 'Example App.app' "$activation_log"
      grep -q 'Downloads' "$activation_log"
      source ${activation empty}
      test "$(grep -c 'defaults write com.apple.dock' "$activation_log")" = 4
      colima_fixture="$TMPDIR/colima home"
      DRY_RUN_CMD=echo source ${colimaActivation}
      test ! -e "$colima_fixture"
      DRY_RUN_CMD= source ${colimaActivation}
      test -d "$colima_fixture"
      test "$(${coreutils}/bin/stat -c %a "$colima_fixture")" = 700
      printf 'existing VM state' > "$colima_fixture/existing"
      DRY_RUN_CMD= source ${colimaActivation}
      test "$(cat "$colima_fixture/existing")" = 'existing VM state'
      touch "$out"
    ''
