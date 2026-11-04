{
  nixi,
  lib,
  runCommand,
  ...
}: let
  consumer = {
    outPath = ./fixtures/cli-host;
    rev = "consumer-revision";
  };
  hostModule = home: _: {
    config = {
      user = {
        name = "alice";
        inherit home;
      };
      home.stateVersion = "26.05";
      system.stateVersion =
        if lib.hasPrefix "/Users/" home
        then 6
        else "26.05";
      hey.enable = false;
    };
  };
  outputs = nixi.lib.mkHostFlake {
    inputs = {
      self = consumer;
      inherit nixi;
    };
    hosts = {
      laptop = {
        system = "aarch64-darwin";
        module = hostModule "/Users/alice";
      };
      server = {
        system = "x86_64-linux";
        module = hostModule "/home/alice";
      };
    };
  };
  configs = [outputs.darwinConfigurations.laptop.config outputs.nixosConfigurations.server.config];
  # Exercise modules independently, with no consumer packages or workstation
  # profile supplying their internal dependencies.
  featureHosts = [outputs.darwinConfigurations.laptop outputs.nixosConfigurations.server];
  enableFeature = host: group: name:
    host.extendModules {
      modules = [
        {modules.profiles.user = "alice";}
        {modules.${group}.${name}.enable = true;}
      ];
    };
  hasPackage = name: host: lib.any (p: lib.getName p == name) host.config.users.users.alice.packages;
  # Start from the preset alone: its mkDefault enable must not recurse, and a
  # consumer's ordinary false (or mkForce false) must suppress all side effects.
  presetMatrix = host: group: name: let
    preset = enableFeature host "profiles" "${name}-workstation";
    disabled = map (value:
      preset.extendModules {
        modules = [{modules.${group}.${name}.enable = value;}];
      }) [false (lib.mkForce false)];
    baseline = host.config;
    noEffects = variant: let
      cfg = variant.config;
      home = cfg.home-manager.users.alice.home;
      baseHome = baseline.home-manager.users.alice.home;
    in
      !cfg.modules.${group}.${name}.enable
      && map lib.getName cfg.users.users.alice.packages == map lib.getName baseline.users.users.alice.packages
      && builtins.attrNames cfg.home.configFile == builtins.attrNames baseline.home.configFile
      && home.sessionVariables == baseHome.sessionVariables
      && home.sessionPath == baseHome.sessionPath
      && cfg.modules.shell.zsh.rcFiles == baseline.modules.shell.zsh.rcFiles
      && cfg.modules.shell.zsh.rcInit == baseline.modules.shell.zsh.rcInit
      && cfg.modules.shell.zsh.envInit == baseline.modules.shell.zsh.envInit
      && cfg.hey.hooks == baseline.hey.hooks
      && cfg.environment.shellAliases == baseline.environment.shellAliases
      && (host.pkgs.stdenv.isDarwin
        || (
          cfg.systemd.tmpfiles.rules
          == baseline.systemd.tmpfiles.rules
          && cfg.systemd.user.tmpfiles.rules == baseline.systemd.user.tmpfiles.rules
          && cfg.users.defaultUserShell == baseline.users.defaultUserShell
        ));
  in
    preset.config.modules.${group}.${name}.enable && lib.all noEffects disabled;
  featureMatrix = host: let
    tmux = enableFeature host "shell" "tmux";
    zsh = enableFeature host "shell" "zsh";
    tmuxPreset = tmux.extendModules {modules = [{modules.profiles.tmux-workstation.enable = true;}];};
    zshPreset = zsh.extendModules {modules = [{modules.profiles.zsh-workstation.enable = true;}];};
    rust = enableFeature host "dev" "rust";
    go = enableFeature host "dev" "go";
    vim = enableFeature host "editors" "vim";
    atuin = enableFeature host "shell" "atuin";
    rustPreset = enableFeature host "profiles" "rust-workstation";
    stableRust = rust.extendModules {modules = [{modules.dev.rust.packageSet = "stable";}];};
    stableRustPreset = rustPreset.extendModules {modules = [{modules.dev.rust.packageSet = "stable";}];};
    selectsRustPackages = variant: source: names: let
      selected = map (p: p.drvPath) variant.config.users.users.alice.packages;
    in
      lib.all (name: builtins.elem source.${name}.drvPath selected) names;
    goPreset = enableFeature host "profiles" "go-workstation";
    goOverride = goPreset.extendModules {
      modules = [
        {
          home-manager.users.alice.home.sessionVariables = {
            GOPATH = "/custom/go";
            GOBIN = "/custom/go/bin";
          };
        }
      ];
    };
    vimPreset = enableFeature host "profiles" "vim-workstation";
    atuinPreset = enableFeature host "profiles" "atuin-workstation";
    atuinOverride = atuinPreset.extendModules {
      modules = [
        {
          modules.shell.atuin = {
            disableUpArrow = false;
            settings.style = "full";
          };
        }
      ];
    };
    vimOverride = vimPreset.extendModules {modules = [{environment.shellAliases.v = "custom-editor";}];};
    presetWithZsh = variant: variant.extendModules {modules = [{modules.shell.zsh.enable = true;}];};
    codegraph = enableFeature host "agents" "codegraph";
    externalCodegraph = codegraph.extendModules {
      modules = [{modules.agents.codegraph.package = null;}];
    };
    alacritty = enableFeature host "shell" "alacritty";
    git = enableFeature host "shell" "git";
    gitVariants =
      [git]
      ++ map (shell:
        git.extendModules {
          modules = [{users.users.alice.shell = lib.mkForce shell;}];
        }) [host.pkgs.bashInteractive host.pkgs.fish];
    gitWithZsh = git.extendModules {modules = [{modules.shell.zsh.enable = true;}];};
    shellVariants =
      [alacritty]
      ++ map (shell:
        alacritty.extendModules {
          modules = [{users.users.alice.shell = lib.mkForce shell;}];
        }) [host.pkgs.bashInteractive host.pkgs.fish];
    terminalUsesConfiguredShell = variant: let
      settings = builtins.fromTOML (builtins.unsafeDiscardStringContext variant.config.home.configFile."alacritty/alacritty.toml".text);
      shell = variant.config.users.users.alice.shell;
    in
      (
        if host.pkgs.stdenv.isDarwin && shell != null
        then
          settings.terminal.shell.program
          == (
            if lib.isDerivation shell
            then "${shell}${shell.shellPath}"
            else toString shell
          )
          && settings.terminal.shell.args == ["-l"]
        else !(settings ? terminal.shell)
      )
      && settings.env.TERM == "alacritty"
      && settings.env.TERMINFO == "${lib.getOutput "terminfo" host.pkgs.alacritty}/share/terminfo"
      && !(settings ? colors)
      && !(settings ? font)
      && !(settings ? hints)
      && !(settings ? window);
    activationEvaluates = variant:
      builtins.stringLength (
        if host.pkgs.stdenv.isDarwin
        then variant.config.system.activationScripts.script.text
        else variant.config.system.activationScripts.script
      )
      > 0;
  in
    hasPackage "tmux" tmux
    && !hasPackage "hey-tmux-status" tmux
    && !hasPackage "tmuxsel" tmux
    && !tmux.config.modules.shell.zsh.enable
    && tmux.config.modules.shell.zsh.rcFiles == []
    && !(tmux.config.home.configFile ? "tmux/bin")
    && !(zsh.config.home.configFile ? "zsh/plugins.zsh")
    && !hasPackage "fzf" zsh
    && zsh.config.modules.shell.zsh.rcInit == ""
    && !(zsh.config.home-manager.users.alice.home.sessionVariables ? _ZO_DATA_DIR)
    && hasPackage "hey-tmux-status" tmuxPreset
    && tmuxPreset.config.home.configFile ? "tmux/bin"
    && zshPreset.config.home.configFile ? "zsh/plugins.zsh"
    && hasPackage "fzf" zshPreset
    && hasPackage "rustc" rust
    && hasPackage "cargo" rust
    && selectsRustPackages rust host.pkgs.unstable ["rustc" "cargo"]
    && selectsRustPackages stableRust host.pkgs ["rustc" "cargo"]
    && selectsRustPackages rustPreset host.pkgs.unstable ["rustfmt" "clippy" "rust-analyzer" "cargo-llvm-cov"]
    && selectsRustPackages stableRustPreset host.pkgs ["rustfmt" "clippy" "rust-analyzer" "cargo-llvm-cov"]
    && !hasPackage "rustfmt" rust
    && !hasPackage "cargo-audit" rust
    && hasPackage "go" go
    && !hasPackage "gopls" go
    && !(go.config.home-manager.users.alice.home.sessionVariables ? GOPATH)
    && hasPackage "neovim" vim
    && !hasPackage "editorconfig-core-c" vim
    && !(vim.config.environment.shellAliases ? v)
    && hasPackage "atuin" atuin
    && atuin.config.modules.shell.atuin.settings
    == {
      auto_sync = false;
      update_check = false;
    }
    && !atuin.config.modules.shell.atuin.disableUpArrow
    && lib.all (variant:
      !variant.config.modules.shell.zsh.enable
      && variant.config.modules.shell.zsh.rcFiles == []
      && variant.config.modules.shell.zsh.rcInit == "") [rust go vim atuin rustPreset goPreset vimPreset atuinPreset tmuxPreset]
    && hasPackage "rustfmt" rustPreset
    && hasPackage "cargo-audit" rustPreset
    && hasPackage "gopls" goPreset
    && goOverride.config.home-manager.users.alice.home.sessionVariables.GOPATH == "/custom/go"
    && goOverride.config.home-manager.users.alice.home.sessionVariables.GOBIN == "/custom/go/bin"
    && goPreset.config.home-manager.users.alice.home.sessionVariables.GOPATH
    == "/${
      if host.pkgs.stdenv.isDarwin
      then "Users"
      else "home"
    }/alice/.config/go"
    && hasPackage "editorconfig-core-c" vimPreset
    && vimPreset.config.environment.shellAliases.v == "nvim"
    && vimOverride.config.environment.shellAliases.v == "custom-editor"
    && atuinPreset.config.modules.shell.atuin.settings.style == "compact"
    && !atuinOverride.config.modules.shell.atuin.settings.auto_sync
    && !atuinOverride.config.modules.shell.atuin.settings.update_check
    && atuinOverride.config.modules.shell.atuin.settings.style == "full"
    && !atuinOverride.config.modules.shell.atuin.disableUpArrow
    && lib.hasInfix "atuin init zsh --disable-up-arrow" (presetWithZsh atuinPreset).config.modules.shell.zsh.rcInit
    && lib.any (file: lib.hasSuffix "/dev/rust/aliases.zsh" (toString file)) (presetWithZsh rustPreset).config.modules.shell.zsh.rcFiles
    && lib.any (file: lib.hasSuffix "/dev/go/aliases.zsh" (toString file)) (presetWithZsh goPreset).config.modules.shell.zsh.rcFiles
    && lib.all (name: presetMatrix host "shell" name) ["zsh" "tmux" "atuin"]
    && lib.all (name: presetMatrix host "dev" name) ["rust" "go"]
    && presetMatrix host "editors" "vim"
    && hasPackage "codegraph" codegraph
    && !hasPackage "codegraph" externalCodegraph
    && hasPackage "alacritty" alacritty
    && !alacritty.config.modules.shell.zsh.enable
    && lib.all (variant:
      !variant.config.modules.shell.zsh.enable
      && variant.config.modules.shell.zsh.rcFiles == []
      && variant.config.home-manager.users.alice.programs.git.enable)
    gitVariants
    && lib.any (file: lib.hasSuffix "/git/aliases.zsh" (toString file)) gitWithZsh.config.modules.shell.zsh.rcFiles
    && lib.all terminalUsesConfiguredShell shellVariants
    && lib.all activationEvaluates ([tmux codegraph alacritty gitWithZsh] ++ gitVariants);
  workstation =
    (outputs.darwinConfigurations.laptop.extendModules {
      modules = [{modules.profiles.workstation.enable = true;}];
    })
    .config;
  homePreset =
    (outputs.darwinConfigurations.laptop.extendModules {
      modules = [{modules.profiles.home-workstation.enable = true;}];
    }).config;
  enabled =
    (outputs.darwinConfigurations.laptop.extendModules {
      modules = [{hey.enable = lib.mkForce true;}];
    })
    .config;
  policy = nixi.lib.mkHostFlake {
    inputs = {
      self = consumer;
      inherit nixi;
    };
    hosts.laptop = {
      system = "aarch64-darwin";
      module = hostModule "/Users/alice";
    };
    hostModules = [{environment.variables.NIXI_POLICY = "consumer";}];
    nixpkgsConfig.allowUnfree = true;
    packages.probe = {config, ...}: {inheritedUnfree = config.allowUnfree;};
  };
  minimal = config:
    !(lib.any (p: (lib.getName p) == "hey" || (lib.getName p) == "skaffold") config.environment.systemPackages)
    && !(config.home.dataFile ? "hey/info.json")
    && config.modules.editors.default == null
    && !(config.env ? EDITOR)
    && !(config.home-manager.users.alice.home.sessionVariables ? EDITOR)
    && !(config.home-manager.users.alice.home.sessionVariables ? XDG_DESKTOP_DIR)
    && !(config.home-manager.users.alice.home.sessionVariables ? XDG_FAKE_HOME)
    && config.system.configurationRevision == "consumer-revision"
    && config.home-manager.users.alice.home.stateVersion == "26.05"
    && !(config.nixpkgs.pkgs.config.allowUnfree or false)
    && !(builtins.elem "alice" config.nix.settings.trusted-users);
in
  assert lib.all (host: let
    diagnosticHost = host.extendModules {
      modules = [
        {
          hey.enable = lib.mkForce true;
          hey.diagnostics.enable = true;
        }
      ];
    };
    names = map lib.getName diagnosticHost.config.environment.systemPackages;
  in
    !host.pkgs.stdenv.isLinux || (builtins.elem "lsof" names && builtins.elem "procps" names))
  [outputs.nixosConfigurations.server outputs.darwinConfigurations.laptop];
  assert builtins.all minimal configs;
  assert homePreset.home-manager.users.alice.home.sessionVariables.XDG_DESKTOP_DIR == homePreset.home.fakeDir;
  assert !(outputs ? packages);
  assert lib.all featureMatrix featureHosts;
  # Attribute-level policy checks alone do not force activation generation.
  assert builtins.stringLength outputs.nixosConfigurations.server.config.system.activationScripts.script > 0;
  assert builtins.stringLength outputs.darwinConfigurations.laptop.config.system.activationScripts.script.text > 0;
  assert !outputs.darwinConfigurations.laptop.config.homebrew.enable;
  assert !outputs.darwinConfigurations.laptop.config.modules.desktop.dock.enable;
  assert outputs.darwinConfigurations.laptop.config.system.defaults.dock.persistent-apps == null;
  assert outputs.darwinConfigurations.laptop.config.system.defaults.dock.persistent-others == null;
  assert outputs.darwinConfigurations.laptop.config.homebrew.onActivation.cleanup == "none";
  assert !outputs.darwinConfigurations.laptop.config.homebrew.onActivation.upgrade;
  assert !outputs.darwinConfigurations.laptop.config.homebrew.onActivation.autoUpdate;
  assert outputs.darwinConfigurations.laptop.config.fonts.packages == [];
  assert outputs.nixosConfigurations.server.config.networking.firewall.enable;
  assert !(outputs.nixosConfigurations.server.config.environment.variables ? XDG_RUNTIME_DIR);
  assert !workstation.hey.enable;
  assert lib.any (p: lib.getName p == "skaffold") workstation.environment.systemPackages;
  assert enabled.home.dataFile ? "hey/info.json";
  assert lib.any (p: lib.getName p == "hey") enabled.environment.systemPackages;
  assert policy.darwinConfigurations.laptop.config.environment.variables.NIXI_POLICY == "consumer";
  assert policy.darwinConfigurations.laptop.config.nixpkgs.pkgs.config.allowUnfree;
  assert policy.darwinConfigurations.laptop.config.nixpkgs.pkgs.unstable.config.allowUnfree;
  assert policy.packages.aarch64-darwin.probe.inheritedUnfree;
    runCommand "minimal-consumer-check" {} ''touch "$out"''
