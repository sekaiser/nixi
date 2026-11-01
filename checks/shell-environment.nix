{
  nixi,
  lib,
  coreutils,
  bash,
  python3,
  callPackage,
  writeShellScriptBin,
  writeText,
  runCommand,
  ...
}: let
  literal = ''    literal $(printf expanded) "quotes" 'single' `printf nope` $HOME
        second line'';
  literalPath = ''/fixture/space "quote" 'single' $(printf UNSAFE >&2) `printf UNSAFE >&2` $HOME'';
  fakeJanet = writeShellScriptBin "janet" ''
    exec ${python3}/bin/python3 -c 'import json, os, sys; print(json.dumps({"env": dict(os.environ), "argv": sys.argv[1:]}))' "$@"
  '';
  launcherArgs = {
    heyDir = literalPath;
    heyBinDir = "${literalPath}/bin";
    heyJanetDeps = "${literalPath}/deps";
    heyJanetLib = "${literalPath}/lib";
    processSupervisor = "${literalPath}/supervisor";
    janet = fakeJanet;
  };
  defaultLauncher = callPackage ../packages/hey.nix launcherArgs;
  literalLauncher = callPackage ../packages/hey.nix (launcherArgs // {homeBinDir = literalPath;});
  runtimeLink = callPackage ../packages/hey-janet-lib.nix {heyRuntimeDir = literalPath;};
  launcherFixture = writeText "hey-launcher-fixture.json" (builtins.toJSON {
    literal = literalPath;
    default = "${defaultLauncher}/bin/hey";
    explicit = "${literalLauncher}/bin/hey";
    runtimeLink = "${runtimeLink}/hey";
  });
  outputs = nixi.lib.mkHostFlake {
    inputs = {
      self.outPath = ./fixtures/cli-host;
      inherit nixi;
    };
    hosts = lib.genAttrs ["linux" "darwin"] (platform: {
      system =
        if platform == "linux"
        then "x86_64-linux"
        else "aarch64-darwin";
      module = _: {
        config = {
          user = {
            name = "alice";
            home = "/fixture/alice";
          };
          home.stateVersion = "26.05";
          system.stateVersion =
            if platform == "linux"
            then "26.05"
            else 6;
          modules.profiles.zsh-workstation.enable = true;
          hey.enable = true;
          modules.profiles.go-workstation.enable = true;
          modules.profiles.tmux-workstation.enable = true;
          modules.shell.awscli2.enable = true;
          modules.services.docker.enable = true;
          modules.editors.default = "selected-editor";
          env.NIXI_LITERAL = literal;
          env.NIXI_LIST = ["one two" "$HOME"];
          home-manager.users.alice.xdg = {
            configHome = "/custom/config";
            dataHome = "/custom/data";
            stateHome = "/custom/state";
          };
          users.users.bob.home = "/fixture/bob";
          home-manager.users.bob = {
            home.stateVersion = "26.05";
            home.sessionVariables.EDITOR = "bob-editor";
            xdg.enable = true;
          };
        };
      };
    });
  };
  hosts = [outputs.nixosConfigurations.linux outputs.darwinConfigurations.darwin];
  shellVariants = host:
    map (enabled:
      host.extendModules {
        modules = [
          {
            modules.shell.zsh.enable = lib.mkForce enabled.zsh;
            modules.profiles.tmux-workstation.enable = lib.mkForce enabled.tmux;
          }
        ];
      }) [
      {
        zsh = true;
        tmux = true;
      }
      {
        zsh = true;
        tmux = false;
      }
      {
        zsh = false;
        tmux = true;
      }
    ];
  zshPaths = host: let
    # Inspect the native user option: `user` is an alias, not the merged profile.
    packages = host.config.users.users.alice.packages ++ host.config.environment.systemPackages;
  in
    lib.unique (map toString (lib.filter (p: lib.getName p == "zsh") packages));
  # Run generated shell code, not a reconstructed list of variables. Substitute
  # only foreign-platform executables and HM file references for native fixtures.
  fixture = host: user: expectedEditor: let
    config = host.config;
    raw =
      if host.pkgs.stdenv.isLinux
      then config.system.build.setEnvironment.text
      else config.environment.extraInit;
    users = lib.attrValues config.home-manager.users;
    script =
      builtins.replaceStrings
      (["${host.pkgs.coreutils}/bin/id -un"] ++ map (hm: "${hm.home.sessionVariablesPackage}/etc/profile.d/hm-session-vars.sh") users)
      (["${coreutils}/bin/printf '%s' ${user}"] ++ map (hm: toString (writeText "session-vars-${hm.home.username}" (builtins.unsafeDiscardStringContext hm.home.sessionVariablesPackage.text))) users)
      (builtins.unsafeDiscardStringContext raw);
    test =
      if user == "alice"
      then ''
        test "$ZDOTDIR" = /custom/config/zsh
        test -z "''${ZGEN_DIR-}"
        test "$HISTFILE" = /custom/state/zsh/history
        test "$_ZO_DATA_DIR" = /custom/data/zoxide
        test "$GOPATH" = /custom/config/go
        test "$GOBIN" = /custom/config/go/bin
        test "$TMUX_HOME" = /custom/config/tmux
        test "$TMUXIFIER" = /custom/data/tmuxifier
        test "$AWS_CONFIG_FILE" = /custom/config/aws/config
        test "$DOCKER_CONFIG" = /custom/config/docker
        case ":$PATH:" in *:/custom/data/tmuxifier/bin:*) ;; *) exit 1 ;; esac
      ''
      else ''
        test "$XDG_CONFIG_HOME" = /fixture/bob/.config
        test -z "''${ZDOTDIR-}"
        test -z "''${ZGEN_DIR-}"
        test -z "''${HISTFILE-}"
        test -z "''${_ZO_DATA_DIR-}"
        test -z "''${GOPATH-}"
        test -z "''${TMUX_HOME-}"
        test -z "''${AWS_CONFIG_FILE-}"
        test -z "''${DOCKER_CONFIG-}"
      '';
  in
    writeText "shell-${host.pkgs.stdenv.hostPlatform.system}-${user}" (script
      + "\nset -eu\n"
      + test
      + ''
        if [ "$EDITOR" != ${lib.escapeShellArg expectedEditor} ]; then
          printf 'EDITOR mismatch for %s: expected %s, got %s\n' ${lib.escapeShellArg user} ${lib.escapeShellArg expectedEditor} "$EDITOR" >&2
          exit 1
        fi
        test "$NIXI_LITERAL" = ${lib.escapeShellArg literal}
        test "$NIXI_LIST" = 'one two:$HOME'
      '');
  editorVariants = host: [
    {
      inherit host;
      expected = "selected-editor";
    }
    {
      host = host.extendModules {modules = [{modules.editors.default = lib.mkForce null;}];};
      expected = host.config.environment.variables.EDITOR or "inherited-editor";
    }
    {
      host = host.extendModules {
        modules = [
          {
            modules.editors.default = lib.mkForce null;
            environment.variables.EDITOR = "native-system-editor";
          }
        ];
      };
      expected = "native-system-editor";
    }
    {
      host = host.extendModules {
        modules = [
          {
            home-manager.users.alice.home.sessionVariables.EDITOR = "native-user-editor";
          }
        ];
      };
      expected = "native-user-editor";
    }
  ];
in
  # Zsh and tmux must compose without selecting a second Zsh from unstable.
  assert lib.assertMsg
  (lib.all (host: lib.all (variant: zshPaths variant == [(toString variant.pkgs.zsh)]) (shellVariants host)) hosts)
  "Zsh and tmux presets must share the host's Zsh package on Linux and Darwin";
  assert lib.all (host: let
    invalid = (host.extendModules {modules = [{env."INVALID-NAME" = "x";}];}).config;
  in
    lib.any (a: !a.assertion && lib.hasInfix "env names" a.message) invalid.assertions)
  hosts;
  assert lib.all (host: lib.all (name: !(builtins.hasAttr name host.config.environment.variables) && !(builtins.hasAttr name host.config.env)) ["ZDOTDIR" "ZGEN_DIR" "HISTFILE" "_ZO_DATA_DIR"]) hosts;
  assert lib.all (host: !(host.config.env ? EDITOR) && host.config.home-manager.users.alice.home.sessionVariables.EDITOR == "selected-editor") hosts;
  assert lib.all (host:
    !(lib.hasInfix "*.zwc" (host.config.system.activationScripts.postActivation.text or ""))
    && host.config.home-manager.users.alice.home.activation ? cleanupLegacyZshCaches
    && host.config.home-manager.users.alice.home.sessionVariables.HEY_TMUX_SELECTOR == lib.getExe host.config.modules.shell.tmux.sessionSelector)
  hosts;
  assert lib.all (host: let
    sourceBin = "${nixi}/bin";
  in
    !lib.hasInfix "${sourceBin}:" host.config.environment.extraInit
    && !lib.hasInfix "${sourceBin}:" host.config.programs.zsh.shellInit)
  hosts;
    runCommand "shell-environment-check" {} ''
      ${python3}/bin/python3 - ${launcherFixture} <<'PY'
      import json, os, subprocess, sys
      fixture = json.load(open(sys.argv[1]))
      literal = fixture["literal"]
      assert os.readlink(fixture["runtimeLink"]) == literal + "/hey"
      for mode in ("default", "explicit"):
          package_bin = os.path.dirname(fixture[mode])
          assert sorted(os.listdir(package_bin)) == ["hey", "myip"]
          for inherited in (None, "", literal + "/override"):
              env = {"HOME": literal + "/home"}
              if inherited is not None:
                  env["XDG_BIN_HOME"] = inherited
              args = ["space arg", literal, ""]
              result = subprocess.run([fixture[mode], *args], env=env,
                                      capture_output=True, text=True, timeout=5, check=True)
              assert result.stderr == "", result.stderr
              actual = json.loads(result.stdout)
              expected = inherited or (env["HOME"] + "/.local/bin" if mode == "default" else literal)
              assert actual["env"]["XDG_BIN_HOME"] == expected, actual
              for key, value in {
                  "HEY_FLAKE_ROOT": literal,
                  "HEY_FRAMEWORK_ROOT": literal,
                  "DOTFILES_BIN": literal + "/bin",
                  "JANET_TREE": literal + "/deps",
                  "JANET_PATH": literal + "/deps/lib:" + literal + "/lib",
                  "HEY_PROCESS_SUPERVISOR": literal + "/supervisor/bin/nixi-process-supervisor",
              }.items():
                  assert actual["env"][key] == value, (key, actual)
              assert actual["argv"] == ["-m", literal + "/lib", literal + "/bin/hey.janet", *args], actual
          result = subprocess.run([os.path.join(package_bin, "myip"), "-w", "space arg", ""],
                                  env={"HOME": "/fixture/home"}, capture_output=True, text=True, timeout=5, check=True)
          assert result.stderr == "", result.stderr
          assert json.loads(result.stdout)["argv"] == ["-m", literal + "/lib", literal + "/bin/hey.janet", "info", "-r", "ip", "-w", "space arg", ""]
      PY
      ${lib.concatMapStringsSep "\n" (host:
        lib.concatMapStringsSep "\n" (variant:
          lib.concatMapStringsSep "\n" (user: ''
            ${coreutils}/bin/env -i HOME=/fixture/${user} USER=${user} \
              EDITOR=${lib.escapeShellArg (variant.host.config.environment.variables.EDITOR or "inherited-editor")} \
              ${bash}/bin/bash --noprofile --norc ${fixture variant.host user (
              if user == "alice"
              then variant.expected
              else "bob-editor"
            )}
          '') ["alice" "bob"])
        (editorVariants host))
      hosts}
      touch "$out"
    ''
