{
  description = "Java project";

  inputs = {
    nixpkgs.url = "nixpkgs/nixos-unstable";
  };

  outputs = {
    self,
    nixpkgs,
  }: let
    systems = [
      "aarch64-darwin"
      "aarch64-linux"
      "x86_64-linux"
    ];
    forAllSystems = f:
      nixpkgs.lib.genAttrs systems (system:
        f {
          pkgs = import nixpkgs {inherit system;};
        });
  in {
    devShells = forAllSystems ({pkgs}: {
      default = pkgs.mkShell {
        packages = with pkgs; [
          gradle
          maven
          openjdk25
          process-compose
        ];

        shellHook = ''
          mkdir -p "$XDG_CONFIG_HOME/jdks"
          if [ ! -e "$XDG_CONFIG_HOME/jdks/${pkgs.openjdk25.name}" ]; then
            ln -s ${pkgs.openjdk25} "$XDG_CONFIG_HOME/jdks/${pkgs.openjdk25.name}"
          fi
        '';
      };
    });

    checks = forAllSystems ({pkgs}: {
      test = pkgs.runCommand "java-project-test" {} ''
        cp -R ${self} source
        chmod -R u+w source
        cd source
        export HOME=$TMPDIR
        export MAVEN_USER_HOME=$TMPDIR/.m2
        ${pkgs.maven}/bin/mvn -Dmaven.repo.local=$TMPDIR/.m2/repository test
        touch $out
      '';
    });
  };
}
