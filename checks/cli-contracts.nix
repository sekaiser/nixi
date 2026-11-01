{
  nixi,
  stdenv,
  writeText,
  janet,
  jpm,
  callPackage,
  git,
  coreutils,
  nix,
  jq,
  rsync,
  ripgrep,
  tmux,
  zsh,
  gnused,
  gawk,
  findutils,
  diffutils,
  runCommand,
  ...
}: let
  deps = callPackage ../packages/hey-janet-deps.nix {inherit janet jpm;};
  supervisor = callPackage ../packages/process-supervisor.nix {};
  python = callPackage ../packages/hey-python.nix {};
  outputs = nixi.lib.mkHostFlake {
    inputs = {
      self.outPath = ./fixtures/cli-host;
      inherit nixi;
    };
    hosts.fixture = {
      system = stdenv.hostPlatform.system;
      module = _: {
        config = {
          user.name = "alice";
          user.home =
            if stdenv.isDarwin
            then "/Users/alice"
            else "/home/alice";
          home.stateVersion = "26.05";
          system.stateVersion =
            if stdenv.isDarwin
            then 6
            else "26.05";
          hey.enable = true;
        };
      };
    };
  };
  host =
    outputs.${
      if stdenv.isDarwin
      then "darwinConfigurations"
      else "nixosConfigurations"
    }.fixture;
  commands = writeText "synthetic-command-manifest.json" host.config.home.dataFile."hey/commands.json".text;
in
  runCommand "cli-contracts-check" {
    src = ../.;
    nativeBuildInputs = [python janet git coreutils nix jq rsync ripgrep tmux zsh gnused gawk findutils diffutils];
  } ''
    export PYTHONDONTWRITEBYTECODE=1
    export JANET_PATH="${deps}/lib"
    export JANET_TREE="${deps}"
    export HEY_PROCESS_SUPERVISOR="${supervisor}/bin/nixi-process-supervisor"
    export HEY_RUNTIME_PYTHON="${python}/bin/python3"
    export NIXI_COMMAND_FIXTURE="${commands}"
    python "$src/test_tools/run_contract_tests.py"
    touch "$out"
  ''
