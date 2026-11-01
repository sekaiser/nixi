{
  ripgrep,
  runCommand,
  ...
}:
runCommand "home-file-ownership-check" {
  src = ../.;
  nativeBuildInputs = [
    ripgrep
  ];
} ''
  cd "$src"

  if rg -n --glob '*.nix' 'force\s*=\s*(true|lib\.mkDefault true|mkDefault true)\s*;' modules; then
    echo "Framework modules must not force-overwrite existing user files." >&2
    echo "Keep Home Manager collision checks; consumers may opt into backups or replacement." >&2
    exit 1
  fi

  touch "$out"
''
