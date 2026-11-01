{
  python3,
  runCommand,
  ...
}:
runCommand "ci-check-plan-check" {src = ../.;} ''
  export PYTHONDONTWRITEBYTECODE=1
  ${python3}/bin/python3 "$src/test_tools/test_check_plan.py"
  touch "$out"
''
