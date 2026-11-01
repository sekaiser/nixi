{
  description = "Go project";

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
          air
          go
          golangci-lint
          gopls
          gotestsum
          govulncheck
          process-compose
        ];
      };
    });

    checks = forAllSystems ({pkgs}: {
      test = pkgs.runCommand "go-project-test" {} ''
        cp -R ${self} source
        chmod -R u+w source
        cd source
        export HOME=$TMPDIR
        export GOCACHE=$TMPDIR/go-cache
        export GOPATH=$TMPDIR/go
        ${pkgs.go}/bin/go test ./...
        touch $out
      '';
    });
  };
}
