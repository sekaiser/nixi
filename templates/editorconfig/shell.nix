{pkgs ? import <nixpkgs> {}}:
with pkgs;
  mkShell {
    buildInputs = [
    ];
    shellHook = ''
      export TEST_CONFIG_USERCONFIG="$PWD/.npm/config"
    '';
  }
