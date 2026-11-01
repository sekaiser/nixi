{
  description = "Algorithm practice workspace";

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
          bacon
          cargo
          cargo-nextest
          clippy
          go
          google-java-format
          gotestsum
          hyperfine
          maven
          openjdk25
          process-compose
          python3
          rust-analyzer
          rustc
          rustfmt
          watchexec
        ];
      };
    });

    checks = forAllSystems ({pkgs}: {
      test = pkgs.runCommand "practice-template-test" {} ''
        cp -R ${self} source
        chmod -R u+w source
        cd source

        export HOME=$TMPDIR
        export GOCACHE=$TMPDIR/go-cache
        export GOPATH=$TMPDIR/go
        export JAVA_HOME=${pkgs.openjdk25}
        export MAVEN_USER_HOME=$TMPDIR/.m2
        export PATH=${pkgs.openjdk25}/bin:$PATH

        (cd rust && ${pkgs.cargo}/bin/cargo check --all-targets)
        (cd go && ${pkgs.go}/bin/go test ./...)
        (cd java && ${pkgs.maven}/bin/mvn -Dmaven.repo.local=$TMPDIR/.m2/repository test)

        touch $out
      '';
    });
  };
}
