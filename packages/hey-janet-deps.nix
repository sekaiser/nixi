{
  fetchFromGitHub,
  janet,
  jpm,
  libiconv,
  stdenv,
  ...
}: let
  ldLibPath =
    if stdenv.hostPlatform.isDarwin
    then "${libiconv}/lib"
    else "${stdenv.cc.libc}/lib";

  cmd = fetchFromGitHub {
    owner = "ianthehenry";
    repo = "cmd";
    rev = "b4308de361d0f90dd96cc0f9a8dc6881e0e851c6";
    hash = "sha256-FG11D8/+ZDHudi6PXy0tKFYCbHUyy0KOqMoZJyFCm9s=";
  };
  judge = fetchFromGitHub {
    owner = "ianthehenry";
    repo = "judge";
    rev = "10754df781b34068e05291951db786933ec6b681";
    hash = "sha256-1zvr1WsllZFeKPb4EgdvTpp67lo1T/M8dEXGNHzOHj0=";
  };
  posixSpawn = fetchFromGitHub {
    owner = "andrewchambers";
    repo = "janet-posix-spawn";
    rev = "3e68f493a6c3b8ed5c333750e33a11ea1a3d00f7";
    hash = "sha256-+Xr7Z0ETQi/ofLRBcTcGv6KtTk04V7/Chfg/IZNB7zY=";
  };
  sh = fetchFromGitHub {
    owner = "andrewchambers";
    repo = "janet-sh";
    rev = "221bcc869bf998186d3c56a388c8313060bfd730";
    hash = "sha256-pqpEs/qfHe/e2ywSuqzWZhfw/YHZNkTsKHZHoaoVTc4=";
  };
  spork = fetchFromGitHub {
    owner = "janet-lang";
    repo = "spork";
    rev = "ca774c40040b5b02c6c08a9f23a526523dd4a55e";
    hash = "sha256-oDTpbkA36A8tIF0vyaBA9VurRKn1DqxCZGgY+A1353g=";
  };
in
  stdenv.mkDerivation {
    pname = "hey-janet-deps";
    version = "0.1.0";

    dontUnpack = true;
    nativeBuildInputs = [janet jpm];

    installPhase = ''
      runHook preInstall

      export HOME="$TMPDIR/home"
      export JANET_TREE="$out"
      export JANET_PATH="$out/lib"
      mkdir -p "$HOME" "$out/bin" "$out/lib"

      install_jpm_project() {
        name="$1"
        src="$2"
        work="$TMPDIR/source-$name"
        cp -R "$src" "$work"
        chmod -R u+w "$work"
        (
          cd "$work"
          jpm \
            --tree="$out" \
            --modpath="$out/lib" \
            --binpath="$out/bin" \
            --headerpath="${janet}/include" \
            --libpath="${janet}/lib" \
            --buildpath="$TMPDIR/build-$name" \
            --ldflags="-L${ldLibPath}" \
            --offline \
            install
        )
      }

      install_jpm_project cmd ${cmd}
      install_jpm_project judge ${judge}
      install_jpm_project posix-spawn ${posixSpawn}
      install_jpm_project sh ${sh}
      install_jpm_project spork ${spork}

      # JPM emits /usr/bin/env launchers after the normal source patch phase.
      # That interpreter path is absent from Linux build sandboxes.
      patchShebangs "$out/bin"

      runHook postInstall
    '';
  }
