{
  lib,
  stdenv,
  python3,
  nix,
  runCommand,
  writeShellScriptBin,
  ...
}: let
  library = runCommand "nixi-system-activation-library" {} ''
    mkdir -p "$out"
    cp ${../tools/system_activation.py} "$out/system_activation.py"
  '';
  entry = ''
    import sys
    sys.path.insert(0, "${library}")
    from system_activation import main
    sys.exit(main(${builtins.toJSON (
      if stdenv.isDarwin
      then "Darwin"
      else "Linux"
    )}, "${nix}/bin/nix-env", "${nix}/bin/nix-store"))
  '';
in
  writeShellScriptBin "nixi-system-activate" ''
    unset NIX_PYTHONPATH NIX_PYTHONEXECUTABLE NIX_PYTHONPREFIX PYTHONEXECUTABLE PYTHONPATH PYTHONHOME __PYVENV_LAUNCHER__
    exec ${python3}/bin/python3 -I -c ${lib.escapeShellArg entry} "$@"
  ''
