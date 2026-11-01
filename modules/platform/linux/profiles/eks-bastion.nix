{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) escapeShellArg mkDefault mkEnableOption mkIf mkOption optionalString;
  inherit (lib.types) bool nullOr str;

  cfg = config.modules.profiles.eks-bastion;
  contracts = import ../../../../lib/internal/file-contracts.nix {inherit lib;};
  credentialLibrary = lib.fileset.toSource {
    root = ../../../../tools;
    fileset = lib.fileset.unions [../../../../tools/openvpn_credentials.py ../../../../tools/runtime_input.py];
  };
  runtimeDir = "/run/openvpn-${cfg.openvpn.name}";
  quoteConfigPath = value: "\"${lib.replaceStrings ["\\" "\""] ["\\\\" "\\\""] (toString value)}\"";
in {
  options.modules.profiles.eks-bastion = {
    enable = mkEnableOption "isolated EKS bastion VM";
    openvpn = {
      enable = mkEnableOption "OpenVPN client inside the bastion";
      name = mkOption {
        type = str;
        default = "eks";
        description = "OpenVPN service name.";
      };
      configFile = mkOption {
        type = nullOr contracts.runtimeSecretPath;
        default = null;
        description = "Runtime path to an OpenVPN client config on the bastion.";
      };
      authFile = mkOption {
        type = nullOr contracts.runtimeSecretPath;
        default = null;
        description = "Runtime path to an OpenVPN auth-user-pass file. Used unless authUserFile and authPasswordFile are both set.";
      };
      authUserFile = mkOption {
        type = nullOr contracts.runtimeSecretPath;
        default = null;
        description = "Runtime path to a file containing only the OpenVPN username.";
      };
      authPasswordFile = mkOption {
        type = nullOr contracts.runtimeSecretPath;
        default = null;
        description = "Runtime path to a file containing only the OpenVPN password.";
      };
      privateKeyPasswordFile = mkOption {
        type = nullOr contracts.runtimeSecretPath;
        default = null;
        description = "Runtime path to the OpenVPN client private key password for askpass.";
      };
      autoStart = mkOption {
        type = bool;
        default = true;
        description = "Whether to start the OpenVPN client at boot.";
      };
    };
  };

  config = mkIf cfg.enable {
    assertions = let
      hasSplitOpenvpnAuth = cfg.openvpn.authUserFile != null || cfg.openvpn.authPasswordFile != null;
    in [
      {
        assertion = !cfg.openvpn.enable || cfg.openvpn.configFile != null;
        message = "modules.profiles.eks-bastion.openvpn.configFile must be set when OpenVPN is enabled.";
      }
      {
        assertion = !cfg.openvpn.enable || cfg.openvpn.authFile != null || hasSplitOpenvpnAuth;
        message = "modules.profiles.eks-bastion.openvpn.authFile or split authUserFile/authPasswordFile must be set when OpenVPN is enabled.";
      }
      {
        assertion = !hasSplitOpenvpnAuth || (cfg.openvpn.authUserFile != null && cfg.openvpn.authPasswordFile != null);
        message = "modules.profiles.eks-bastion.openvpn.authUserFile and authPasswordFile must be set together.";
      }
      {
        assertion = !cfg.openvpn.enable || builtins.match "[a-zA-Z0-9][a-zA-Z0-9_.-]*" cfg.openvpn.name != null;
        message = "modules.profiles.eks-bastion.openvpn.name must be a simple service name (letters, digits, dot, underscore or hyphen).";
      }
      {
        assertion =
          !cfg.openvpn.enable
          || lib.all (value:
            value == null || (lib.hasPrefix "/" value && !lib.hasInfix "\n" value && !lib.hasInfix "\r" value)) [
            cfg.openvpn.configFile
            cfg.openvpn.authFile
            cfg.openvpn.authUserFile
            cfg.openvpn.authPasswordFile
            cfg.openvpn.privateKeyPasswordFile
          ];
        message = "OpenVPN runtime paths must be absolute and must not contain newlines.";
      }
    ];

    modules.shell.awscli2.enable = true;
    modules.shell.awscli2.saml.enable = mkDefault true;

    environment.systemPackages = with pkgs; [
      openvpn
      iproute2
      inetutils
      dnsutils
      curl
    ];

    services.openvpn.servers = let
      splitAuth = cfg.openvpn.authUserFile != null && cfg.openvpn.authPasswordFile != null;
      authFile =
        if splitAuth
        then "${runtimeDir}/auth-user-pass"
        else cfg.openvpn.authFile;
    in
      mkIf cfg.openvpn.enable {
        ${cfg.openvpn.name} = {
          autoStart = cfg.openvpn.autoStart;
          config = ''
            config ${quoteConfigPath cfg.openvpn.configFile}
            auth-user-pass ${quoteConfigPath authFile}
            auth-nocache
            ${optionalString (cfg.openvpn.privateKeyPasswordFile != null) "askpass ${quoteConfigPath cfg.openvpn.privateKeyPasswordFile}"}
          '';
        };
      };

    systemd.services."openvpn-${cfg.openvpn.name}" = let
      splitAuth = cfg.openvpn.authUserFile != null && cfg.openvpn.authPasswordFile != null;
    in
      mkIf (cfg.openvpn.enable && splitAuth) {
        preStart = ''
          ${pkgs.coreutils}/bin/install -d -m 0700 ${escapeShellArg runtimeDir}
          ${pkgs.python3}/bin/python ${credentialLibrary}/openvpn_credentials.py \
            ${escapeShellArg cfg.openvpn.authUserFile} \
            ${escapeShellArg cfg.openvpn.authPasswordFile} \
            ${escapeShellArg "${runtimeDir}/auth-user-pass"}
        '';
      };

    security.sudo.extraRules = mkIf cfg.openvpn.enable [
      {
        users = [config.user.name];
        commands = [
          {
            command = "/run/current-system/sw/bin/systemctl start openvpn-${cfg.openvpn.name}.service";
            options = ["NOPASSWD"];
          }
          {
            command = "/run/current-system/sw/bin/systemctl restart openvpn-${cfg.openvpn.name}.service";
            options = ["NOPASSWD"];
          }
          {
            command = "/run/current-system/sw/bin/systemctl reset-failed openvpn-${cfg.openvpn.name}.service";
            options = ["NOPASSWD"];
          }
        ];
      }
    ];
  };
}
