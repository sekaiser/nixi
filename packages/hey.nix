{
  heyBinDir ? "${heyDir}/bin",
  heyDir ? ../.,
  heyJanetDeps ?
    callPackage ./hey-janet-deps.nix {
      inherit janet jpm;
    },
  heyJanetLib ?
    callPackage ./hey-janet-lib.nix {
      heyRuntimeDir = "${heyDir}/runtime";
    },
  homeBinDir ? null,
  processSupervisor ? callPackage ./process-supervisor.nix {},
  runtimePython ? callPackage ./hey-python.nix {},
  lib,
  janet,
  jpm,
  writeShellScriptBin,
  symlinkJoin,
  callPackage,
  ...
}: let
  launcher = writeShellScriptBin "hey" ''
    set -eu

    export JANET_PATH=${lib.escapeShellArg "${heyJanetDeps}/lib:${heyJanetLib}"}
    export JANET_TREE=${lib.escapeShellArg (toString heyJanetDeps)}
    export HEY_PROCESS_SUPERVISOR=${lib.escapeShellArg "${processSupervisor}/bin/nixi-process-supervisor"}
    export HEY_RUNTIME_PYTHON=${lib.escapeShellArg "${runtimePython}/bin/python3"}
    if [ -z "''${XDG_BIN_HOME:-}" ]; then
      XDG_BIN_HOME=${
      if homeBinDir == null
      then ''"$HOME/.local/bin"''
      else lib.escapeShellArg homeBinDir
    }
    fi
    export XDG_BIN_HOME
    export HEY_FLAKE_ROOT=${lib.escapeShellArg (toString heyDir)}
    export HEY_FRAMEWORK_ROOT=${lib.escapeShellArg (builtins.dirOf heyBinDir)}
    export DOTFILES_BIN=${lib.escapeShellArg heyBinDir}

    exec ${lib.escapeShellArg "${janet}/bin/janet"} -m ${lib.escapeShellArg (toString heyJanetLib)} ${lib.escapeShellArg "${heyBinDir}/hey.janet"} "$@"
  '';
  # Explicit executable surface: never copy or glob the framework's bin tree.
  myip = writeShellScriptBin "myip" ''
    exec ${launcher}/bin/hey info -r ip "$@"
  '';
in
  symlinkJoin {
    name = "hey";
    paths = [launcher myip];
    meta.mainProgram = "hey";
  }
