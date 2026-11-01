{
  findutils,
  hey,
  runCommand,
  ...
}:
runCommand "workspace-layout-check" {
  src = hey.outPath;
  nativeBuildInputs = [
    findutils
  ];
} ''
  cd "$src"

  if [ ! -d nixi ]; then
    touch "$out"
    exit 0
  fi

  forbidden="
  assets
  bin
  checks
  default.nix
  devshell.nix
  docs
  host-flake
  lib
  modules
  overlays
  packages
  project.janet
  runtime
  templates
  test
  tools
  vendor
  "

  found=""
  for path in $forbidden; do
    if [ -e "$path" ] || [ -L "$path" ]; then
      found="$found
  $path"
    fi
  done

  if [ -n "$found" ]; then
    echo "workspace root contains framework or host bridge paths:" >&2
    echo "$found" >&2
    echo "Keep framework files under nixi/ and host inventory under hosts/." >&2
    exit 1
  fi

  root_symlinks="$(find . -mindepth 1 -maxdepth 1 -type l -print)"
  if [ -n "$root_symlinks" ]; then
    echo "workspace root must not contain symlink bridges:" >&2
    echo "$root_symlinks" >&2
    exit 1
  fi

  touch "$out"
''
