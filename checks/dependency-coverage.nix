{
  nixi,
  lib,
  python3,
  runCommand,
  ...
}: let
  policy = builtins.fromJSON (builtins.readFile ../security/dependency-coverage.json);
  targets = map (system:
    import ../security/dependency-targets.nix {
      root = toString ../.;
      flake = nixi;
      inherit system;
    })
  policy.systems;
in
  assert lib.all (entry:
    builtins.length (builtins.attrNames entry.targets)
    == (
      if lib.hasSuffix "-linux" entry.system
      then 18
      else 13
    ))
  targets;
  assert lib.all (entry: entry.targets."editor/emacs-base".version == "31.1") targets;
  assert lib.all (entry: lib.all (target: lib.hasSuffix ".drv" target.drvPath) (builtins.attrValues entry.targets)) targets;
    runCommand "dependency-coverage-check" {
      src = ../.;
      nativeBuildInputs = [python3];
    } ''
      export PYTHONDONTWRITEBYTECODE=1
      python "$src/test_tools/test_dependency_scan.py"
      touch "$out"
    ''
