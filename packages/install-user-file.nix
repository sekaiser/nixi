{
  python3,
  lib,
  runCommand,
  writeShellScriptBin,
  ...
}: let
  library = runCommand "nixi-installer-library" {} ''
    mkdir -p "$out"
    cp ${../tools/install_user_file.py} "$out/install_user_file.py"
    cp ${../tools/runtime_input.py} "$out/runtime_input.py"
  '';
  entry = ''
    import sys
    sys.path.insert(0, "${library}")
    from install_user_file import main
    main()
  '';
in
  writeShellScriptBin "nixi-install-user-file" ''
    unset NIX_PYTHONPATH NIX_PYTHONEXECUTABLE NIX_PYTHONPREFIX PYTHONEXECUTABLE PYTHONPATH PYTHONHOME __PYVENV_LAUNCHER__
    exec ${python3}/bin/python3 -I -c ${lib.escapeShellArg entry} "$@"
  ''
