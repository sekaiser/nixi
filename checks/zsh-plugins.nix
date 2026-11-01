{
  nixi,
  lib,
  stdenv,
  zsh,
  bash,
  coreutils,
  python3,
  runCommand,
  writeText,
  ...
}: let
  platform =
    if stdenv.isDarwin
    then "darwin"
    else "linux";
  outputs = nixi.lib.mkHostFlake {
    inputs = {
      self.outPath = ./fixtures/cli-host;
      inherit nixi;
    };
    hosts.review = {
      system = stdenv.hostPlatform.system;
      module = _: {
        config = {
          user = {
            name = "alice";
            home = "/fixture/alice";
          };
          home.stateVersion = "26.05";
          system.stateVersion =
            if stdenv.isDarwin
            then 6
            else "26.05";
          modules.profiles.zsh-workstation.enable = true;
          hey.enable = true;
          hey.hooks.review.failure = "false\nprint should-not-run";
          hey.hooks.review."10-early" = "print early";
          hey.hooks.other.failure = "print other-phase";
        };
      };
    };
  };
  host =
    outputs
    .${
      if stdenv.isDarwin
      then "darwinConfigurations"
      else "nixosConfigurations"
    }
    .review;
  inherit (host) config;
  collisionConfig = enabled:
    (host.extendModules {
      modules = [
        {
          hey.enable = lib.mkForce enabled;
          hey.hooks.review = {
            task = "print task";
            "50-task" = "print prefixed-task";
          };
        }
      ];
    })
    .config;
  plugins = writeText "plugins.zsh" config.home.configFile."zsh/plugins.zsh".text;
  hook = writeText "failing-hook.zsh" config.home.dataFile."hey/hooks.d/review.d/50-failure".text;
  cleanup = writeText "zsh-user-cleanup" config.home-manager.users.alice.home.activation.cleanupLegacyZshCaches.data;
  minimal =
    (host.extendModules {
      modules = [
        {
          modules.profiles.zsh-workstation.enable = lib.mkForce false;
          modules.shell.zsh = {
            enable = true;
            rcInit = "typeset -g NIXI_MINIMAL_INIT=ready";
            envInit = "typeset -g NIXI_MINIMAL_ENV=ready";
          };
        }
      ];
    }).config;
  minimalFixture = writeText "minimal-zsh.json" (builtins.toJSON {
    startup = builtins.unsafeDiscardStringContext minimal.home-manager.users.alice.xdg.configFile."zsh/.zshrc".source.text;
    extra = minimal.home.configFile."zsh/extra.zshrc".text;
    environment = minimal.home.configFile."zsh/.zshenv".text;
  });
  test = writeText "verify-plugins.zsh" ''
    # Startup uses only store sources and private writable state. This build
    # has no network access and needs no pre-existing zgenom checkout.
    source "$ZDOTDIR/.zshrc"
    for fn in zvm_init _zsh_autosuggest_start history-substring-search-up prompt_powerlevel9k_setup autopair-init; do
      (( $+functions[$fn] )) || { print -u2 "missing plugin function: $fn"; exit 1; }
    done
    (( $+functions[compdef] )) || exit 1
    [[ -f $ZCOMPCACHE ]] || exit 1
    [[ $ZCOMPCACHE == $XDG_CACHE_HOME/zsh/*.$NIXI_ZSH_PLUGIN_SET ]] || exit 1
    [[ ! -e $XDG_DATA_HOME/zgenom ]] || exit 1
    print plugins-ready
    exit 0
  '';
  terminalTest = writeText "zsh-terminal-test.py" ''
    import errno, os, pty, select, signal, sys, time
    pid, fd = pty.fork()
    if pid == 0:
        os.execv("${zsh}/bin/zsh", ["zsh", "-f", "-i", "${test}"])
    output = bytearray()
    deadline = time.monotonic() + 30
    try:
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("Zsh startup timed out")
            if not select.select([fd], [], [], remaining)[0]:
                continue
            try:
                chunk = os.read(fd, 65536)
            except OSError as error:
                if error.errno != errno.EIO: raise
                break
            if not chunk: break
            output.extend(chunk)
    except BaseException:
        os.kill(pid, signal.SIGKILL)
        raise
    finally:
        os.close(fd)
        _, status = os.waitpid(pid, 0)
        sys.stdout.buffer.write(output)
    assert os.waitstatus_to_exitcode(status) == 0
    assert b"plugins-ready" in output
    assert b"can't change option" not in output
    assert b"no such file" not in output
    assert b"command not found" not in output
  '';
in
  assert config.home.dataFile ? "hey/hooks.d/review.d/50-failure";
  assert config.home.dataFile ? "hey/hooks.d/review.d/10-early";
  assert config.home.dataFile ? "hey/hooks.d/other.d/50-failure";
  assert !(builtins.tryEval (builtins.attrNames (collisionConfig true).home.dataFile)).success;
  assert (builtins.tryEval (builtins.attrNames (collisionConfig false).home.dataFile)).success;
  assert !(config.home-manager.users.alice.home.sessionVariables ? ZGEN_DIR);
  assert !lib.hasInfix "git clone" (builtins.readFile ../assets/zsh/.zshrc);
  assert !lib.hasInfix "zgenom autoupdate" (builtins.readFile ../bin/hey.d/reload.janet);
    runCommand "zsh-plugins-${platform}-check" {
      passthru = {inherit minimalFixture cleanup;};
      src = ../.;
      nativeBuildInputs = [zsh bash coreutils python3];
    } ''
      export PYTHONDONTWRITEBYTECODE=1
      NIXI_ZSH_CLEANUP=${cleanup} NIXI_ZSH_MINIMAL=${minimalFixture} python "$src/test_tools/test_shell_startup.py"
      mkdir -p state/config/zsh state/cache state/data state/home
      cp ${../assets/zsh}/.zshrc state/config/zsh/.zshrc
      cp ${plugins} state/config/zsh/plugins.zsh
      cp ${../assets/zsh/completion.zsh} state/config/zsh/completion.zsh
      cp ${../assets/zsh/keybinds.zsh} state/config/zsh/keybinds.zsh
      cp ${../assets/zsh/aliases.zsh} state/config/zsh/aliases.zsh
      touch state/config/zsh/extra.zshrc
      for attempt in 1 2; do
        env -i PATH="$PATH" HOME="$PWD/state/home" TERM=xterm-256color \
          ZDOTDIR="$PWD/state/config/zsh" XDG_CONFIG_HOME="$PWD/state/config" \
          XDG_CACHE_HOME="$PWD/state/cache" XDG_DATA_HOME="$PWD/state/data" \
          XDG_STATE_HOME="$PWD/state" \
          ${python3}/bin/python ${terminalTest}
      done
      if ${zsh}/bin/zsh ${hook} >hook.log 2>&1; then
        echo "failing generated hook returned success" >&2
        exit 1
      fi
      test ! -s hook.log
      touch "$out"
    ''
