{
  callPackage,
  openssh,
  runCommand,
  ...
}: let
  python = callPackage ../packages/hey-python.nix {};
in
  runCommand "runtime-inputs-check" {
    src = ../.;
    nativeBuildInputs = [python openssh];
  } ''
    export PYTHONDONTWRITEBYTECODE=1
    export NIXI_TEST_SSHD="${openssh}/bin/sshd"
    python "$src/test_tools/test_runtime_inputs.py"
    python "$src/test_tools/test_ssh_diagnostics.py"
    python "$src/test_tools/test_dependency_report.py"
    touch "$out"
  ''
