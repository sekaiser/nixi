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
    # A present script with a missing shebang interpreter reports ENOENT too.
    read -r judgeShebang < "${deps}/bin/judge"
    test "$judgeShebang" = '#!${janet}/bin/janet'
    python "$src/test_tools/run_cli_tests.py" \
      test_lazy_dispatch_broken_commands_do_not_block_help_or_unrelated_commands \
      test_lazy_dispatch_aliases_forward_arguments_status_and_complete_registry \
      test_lazy_dispatch_missing_module_does_not_fall_back \
      test_lazy_command_loader_caches_import_and_rejects_missing_registration \
      test_external_dispatch_preserves_status_arguments_and_dry_runs
    python "$src/test_tools/run_contract_tests.py"
    touch "$out"
  ''
