{
  python3,
  runCommand,
  ...
}:
runCommand "user-file-installation-check" {
  src = ../.;
  nativeBuildInputs = [python3];
} ''
  export PYTHONDONTWRITEBYTECODE=1
  python "$src/test_tools/test_install_user_file.py"
  touch "$out"
''
