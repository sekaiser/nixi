{
  config,
  hey,
  lib,
  pkgs,
  ...
}: {
  options.modules.profiles.go-workstation.enable = lib.mkEnableOption "Go workstation tools and shell preferences";

  config = lib.mkIf config.modules.profiles.go-workstation.enable (lib.mkMerge [
    {modules.dev.go.enable = lib.mkDefault true;}
    (lib.mkIf config.modules.dev.go.enable {
      home-manager.users.${config.user.name}.home.sessionVariables = {
        GOPATH = lib.mkDefault "${config.home.configDir}/go";
        GOBIN = lib.mkDefault "${config.home.configDir}/go/bin";
      };

      modules.shell.zsh.rcFiles = lib.mkIf config.modules.shell.zsh.enable ["${hey.assetsDir}/dev/go/aliases.zsh"];

      user.packages = [
        pkgs.unstable.go-swag
        # linters and static analysis
        pkgs.unstable.golangci-lint
        pkgs.unstable.gopls
        pkgs.unstable.go-tools
        pkgs.unstable.govulncheck
        pkgs.unstable.delve
        pkgs.unstable.ginkgo
        pkgs.unstable.gotestsum
        pkgs.unstable.air
        pkgs.unstable.protobuf
        pkgs.unstable.protoc-gen-go
        pkgs.unstable.protoc-gen-go-grpc
        pkgs.unstable.grpc-gateway
      ];
    })
  ]);
}
