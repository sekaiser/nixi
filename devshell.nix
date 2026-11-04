{
  alejandra,
  cargo,
  callPackage,
  git,
  janet,
  jpm,
  mkShell,
  nix-output-monitor,
  nix-zsh-completions,
  nixVersions,
  nixd,
  rustc,
  ssh-to-age,
  ...
}: let
  processSupervisor = callPackage ./packages/process-supervisor.nix {};
  runtimePython = callPackage ./packages/hey-python.nix {};
  heyJanetDeps = callPackage ./packages/hey-janet-deps.nix {
    inherit janet jpm;
  };
  frameworkRoot = ''
    if [ -d "$(pwd)/nixi/runtime" ]; then
      NIXI_DEV_ROOT="$(pwd)/nixi"
    else
      NIXI_DEV_ROOT="$(pwd)"
    fi
  '';
  nixConfig = builtins.toFile "nix.conf" ''
    warn-dirty = false
    experimental-features = nix-command flakes
  '';
in
  mkShell {
    packages = [
      alejandra
      cargo
      git
      janet
      jpm
      heyJanetDeps
      processSupervisor
      runtimePython
      nix-output-monitor
      nix-zsh-completions
      nixVersions.nix_2_31
      nixd
      rustc
      ssh-to-age
    ];

    shellHook = ''
      ${frameworkRoot}
      export NIX_USER_CONF_FILES="${nixConfig}"
      export JANET_PATH="${heyJanetDeps}/lib:$NIXI_DEV_ROOT/runtime:$NIXI_DEV_ROOT/vendor/janet''${JANET_PATH:+:$JANET_PATH}"
      export HEY_PROCESS_SUPERVISOR="${processSupervisor}/bin/nixi-process-supervisor"
      export HEY_RUNTIME_PYTHON="${runtimePython}/bin/python3"
      export PATH="$NIXI_DEV_ROOT/bin:$PATH"
    '';
  }
