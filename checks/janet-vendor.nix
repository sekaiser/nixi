{
  findutils,
  runCommand,
  ...
}:
runCommand "janet-vendor-check" {
  src = ../.;
  nativeBuildInputs = [findutils];
} ''
  cd "$src"

  native_outputs="$(
    find runtime vendor/janet -type f \
      \( -name '*.a' -o -name '*.so' -o -name '*.dylib' \) \
      -print
  )"
  if [ -n "$native_outputs" ]; then
    echo "Janet native build outputs do not belong in shared source:" >&2
    echo "$native_outputs" >&2
    exit 1
  fi

  touch "$out"
''
