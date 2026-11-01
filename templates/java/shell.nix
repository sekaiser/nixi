{pkgs ? import <nixpkgs> {}}:
with pkgs;
  mkShell {
    # https://github.com/NixOS/nixpkgs/blob/master/pkgs/top-level/java-packages.nix
    buildInputs = [
      openjdk25
      maven
      gradle
    ];
    shellHook = ''
      if [ ! -d "$XDG_CONFIG_HOME/jdks/${openjdk25.name}" ]; then
        ln --symbolic ${openjdk25} "$XDG_CONFIG_HOME/jdks/${openjdk25.name}"
      fi
    '';
  }
