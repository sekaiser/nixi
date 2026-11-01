{
  findutils,
  gnugrep,
  ripgrep,
  runCommand,
  ...
}:
runCommand "module-layout-check" {
  src = ../.;
  nativeBuildInputs = [
    findutils
    gnugrep
    ripgrep
  ];
} ''
  cd "$src"

  legacy_dirs="$(find modules -mindepth 1 -maxdepth 1 -type d \( -name '*-darwin' -o -name '*-linux' \) -print)"
  if [ -n "$legacy_dirs" ]; then
    echo "legacy system-specific module directories are not allowed:" >&2
    echo "$legacy_dirs" >&2
    exit 1
  fi

  if rg -n 'modules/(aarch64|x86_64)-' .; then
    echo "legacy system-specific module paths are still referenced" >&2
    exit 1
  fi

  invalid_platforms="$(
    find modules/platform -mindepth 1 -maxdepth 1 -type d -print \
      | while IFS= read -r dir; do
          name="$(basename "$dir")"
          case "$name" in
            darwin|linux) ;;
            *) echo "$dir" ;;
          esac
        done
  )"
  if [ -n "$invalid_platforms" ]; then
    echo "platform module directories must be operating systems only:" >&2
    echo "$invalid_platforms" >&2
    exit 1
  fi

  if [ -e modules/arch ]; then
    echo "modules/arch is not part of the public framework layout" >&2
    echo "Use platform modules, shared modules, or explicit host-local imports for CPU-specific policy." >&2
    exit 1
  fi

  if [ -e overlays/default.nix ]; then
    echo "overlays/default.nix is not used; expose overlays as named *.nix files instead" >&2
    exit 1
  fi

  invalid_overlays="$(
    find overlays -maxdepth 1 -type f \
      ! -name README.md \
      ! -name '*.nix' \
      -print
  )"
  if [ -n "$invalid_overlays" ]; then
    echo "overlay files must be README.md or named *.nix files:" >&2
    echo "$invalid_overlays" >&2
    exit 1
  fi

  if find test -type f -name '*.nix' -print | grep .; then
    echo "Nix flake checks belong in checks/, not test/" >&2
    exit 1
  fi

  touch "$out"
''
