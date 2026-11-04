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
    fileset = lib.fileset.unions [../../../../tools/openvpn_client.py ../../../../tools/install_user_file.py ../../../../tools/runtime_input.py];
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
        description = "Root-private runtime OpenVPN client config. Protected root-owned directories/provider links and file references are checked before staging. Scripts, plugins, nested configs and output-file directives are unsupported; use a separately reviewed native service for those.";
      };
      authFile = mkOption {
        type = nullOr contracts.runtimeSecretPath;
        default = null;
        description = "Root-private runtime path to a two-line OpenVPN auth-user-pass file. Mutually exclusive with split authUserFile/authPasswordFile.";
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
      allowUserServiceControl = mkOption {
        type = bool;
        default = false;
        description = "Explicitly grant the selected user passwordless start/restart/reset-failed for this exact root-running service. Inputs remain protected independently of this grant.";
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
        assertion = !cfg.openvpn.enable || !hasSplitOpenvpnAuth || cfg.openvpn.authFile == null;
        message = "OpenVPN combined authFile and split credentials are mutually exclusive.";
      }
      {
        assertion =
          !cfg.openvpn.enable
          || (config.services.openvpn.servers.${cfg.openvpn.name}.up
            == ""
            && config.services.openvpn.servers.${cfg.openvpn.name}.down == ""
            && !config.services.openvpn.servers.${cfg.openvpn.name}.updateResolvConf
            && config.services.openvpn.servers.${cfg.openvpn.name}.authUserPass == null);
        message = "The protected OpenVPN client adapter does not support native hooks or inline credentials; use a separately reviewed native service.";
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
    modules.shell.awscli2.eks.enable = mkDefault true;

    environment.systemPackages = with pkgs; [
      openvpn
      iproute2
      inetutils
      dnsutils
      curl
    ];

    services.openvpn.servers = mkIf cfg.openvpn.enable {
      ${cfg.openvpn.name} = {
        autoStart = cfg.openvpn.autoStart;
        config = ''
          config ${quoteConfigPath "${runtimeDir}/client.conf"}
        '';
      };
    };

    systemd.services."openvpn-${cfg.openvpn.name}" = let
      splitAuth = cfg.openvpn.authUserFile != null && cfg.openvpn.authPasswordFile != null;
    in
      mkIf cfg.openvpn.enable {
        serviceConfig = {
          RuntimeDirectory = "openvpn-${cfg.openvpn.name}";
          RuntimeDirectoryMode = "0700";
        };
        preStart = ''
          ${pkgs.python3}/bin/python -I -c \
            ${escapeShellArg "import sys; sys.path.insert(0, '${credentialLibrary}'); from openvpn_client import main; sys.exit(main())"} \
            --config ${escapeShellArg cfg.openvpn.configFile} \
            --destination ${escapeShellArg runtimeDir} \
            ${
            if splitAuth
            then "--username-file ${escapeShellArg cfg.openvpn.authUserFile} --password-file ${escapeShellArg cfg.openvpn.authPasswordFile}"
            else "--auth-file ${escapeShellArg cfg.openvpn.authFile}"
          } \
            ${optionalString (cfg.openvpn.privateKeyPasswordFile != null) "--key-password-file ${escapeShellArg cfg.openvpn.privateKeyPasswordFile}"}
        '';
      };

    security.sudo.extraRules = mkIf (cfg.openvpn.enable && cfg.openvpn.allowUserServiceControl) [
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
