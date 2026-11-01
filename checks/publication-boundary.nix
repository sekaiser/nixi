{
  python3,
  gitleaks,
  runCommand,
  ...
}:
runCommand "publication-boundary-check" {
  src = ../.;
  nativeBuildInputs = [python3 gitleaks];
} ''
  export PYTHONDONTWRITEBYTECODE=1
  python "$src/test_tools/test_release.py"
  python "$src/tools/release.py" audit --root "$src"
  python "$src/tools/release.py" export --root "$src" --destination "$TMPDIR/export"
  gitleaks dir "$TMPDIR/export" --config ${gitleaks}/etc/gitleaks.toml \
    --redact --no-banner --ignore-gitleaks-allow --timeout 60
  touch "$out"
''
