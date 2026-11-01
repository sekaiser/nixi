{
  callPackage,
  python3,
  janet,
  runCommand,
  ...
}: let
  supervisor = callPackage ../packages/process-supervisor.nix {};
in
  runCommand "process-supervisor-check" {
    src = ../.;
    nativeBuildInputs = [python3 janet];
  } ''
    export PYTHONDONTWRITEBYTECODE=1
    export JANET_PATH="$src/runtime"
    export HEY_PROCESS_SUPERVISOR="${supervisor}/bin/nixi-process-supervisor"
    python "$src/test_tools/test_process_supervisor.py"
    touch "$out"
  ''
