{
  nixi,
  python3,
  janet,
  jpm,
  callPackage,
  git,
  just,
  coreutils,
  nix,
  jq,
  rsync,
  ripgrep,
  watchexec,
  tmux,
  zsh,
  runCommand,
  ...
}: let
  deps = callPackage ../packages/hey-janet-deps.nix {inherit janet jpm;};
  fixtures = (callPackage ./eks-integration.nix {inherit nixi;}).cliFixtures;
  runtimePython = callPackage ../packages/hey-python.nix {};
  supervisor = callPackage ../packages/process-supervisor.nix {};
in
  runCommand "cli-behavior-check" {
    src = ../.;
    nativeBuildInputs = [python3 janet git just coreutils nix jq rsync ripgrep watchexec tmux zsh];
  } ''
    export PYTHONDONTWRITEBYTECODE=1
    export JANET_PATH="${deps}/lib"
    export JANET_TREE="${deps}"
    export HEY_PROCESS_SUPERVISOR="${supervisor}/bin/nixi-process-supervisor"
    export HEY_RUNTIME_PYTHON="${runtimePython}/bin/python3"
    export NIXI_EKS_FIXTURES="${fixtures}"
    python "$src/test_tools/test_cli_runner.py"
    python "$src/test_tools/run_cli_tests.py"
    touch "$out"
  ''
