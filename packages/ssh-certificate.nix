{
  lib,
  python3,
  openssh,
  runCommand,
  writeShellScriptBin,
  ...
}: let
  python = python3.withPackages (ps: [ps.cryptography]);
  library = runCommand "nixi-certificate-library" {} ''
    mkdir -p "$out"
    cp ${../tools/ssh_certificate.py} "$out/ssh_certificate.py"
    cp ${../tools/install_user_file.py} "$out/install_user_file.py"
    cp ${../tools/runtime_input.py} "$out/runtime_input.py"
  '';
  entry = ''
    import sys
    sys.path.insert(0, "${library}")
    from ssh_certificate import main
    sys.exit(main())
  '';
in
  writeShellScriptBin "nixi-ssh-certificate" ''
    # Nix's sitecustomize consumes these even with Python isolated mode.
    unset NIX_PYTHONPATH NIX_PYTHONEXECUTABLE NIX_PYTHONPREFIX PYTHONEXECUTABLE PYTHONPATH PYTHONHOME __PYVENV_LAUNCHER__
    exec ${python}/bin/python3 -I -c ${lib.escapeShellArg entry} --ssh-keygen ${openssh}/bin/ssh-keygen "$@"
  ''
