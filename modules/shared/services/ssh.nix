{
  config,
  hey,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) concatStringsSep escapeShellArg hasPrefix mapAttrsToList mkIf mkOption optionalAttrs;
  inherit (lib.types) attrsOf listOf str submodule;
  inherit (hey.lib) mkBoolOpt' mkOpt';

  cfg = config.modules.services.ssh;
  contracts = import "${hey.frameworkDir}/lib/internal/file-contracts.nix" {inherit lib;};
  quoteConfigPath = import "${hey.frameworkDir}/lib/internal/ssh-config.nix" {inherit lib;};
  certificateTool = pkgs.callPackage "${hey.frameworkDir}/packages/ssh-certificate.nix" {};
  defaultGroup =
    if pkgs.stdenv.hostPlatform.isDarwin
    then "staff"
    else config.users.users.${config.user.name}.group;
  renderUserCertificate = name: cert: ''
    ${certificateTool}/bin/nixi-ssh-certificate user \
      --name=${escapeShellArg name} \
      --ca-key ${escapeShellArg cert.caKeyFile} \
      --public-key ${escapeShellArg cert.publicKeyFile} \
      --certificate ${escapeShellArg cert.certificateFile} \
      --user ${escapeShellArg cert.targetUser} \
      --group ${escapeShellArg cert.targetGroup} \
      --identity=${escapeShellArg cert.identityPrefix} \
      --principals ${escapeShellArg (builtins.toJSON cert.principals)} \
      --validity=${escapeShellArg cert.validity} ${lib.optionalString cert.required "--required"}
    certificate_status=$?
    if [ "$certificate_status" -ne 0 ]; then
      exit "$certificate_status"
    fi
  '';
  userCertificateScript = concatStringsSep "\n" (mapAttrsToList renderUserCertificate cfg.userCertificates);
  renewalScript = pkgs.writeShellScript "nixi-renew-user-certificates" ''
    set -eu
    ${userCertificateScript}
  '';
  renderHostCA = name: ca: let
    patterns = concatStringsSep "," ca.patterns;
  in ''
    @cert-authority ${patterns} ${ca.publicKey}
  '';
  clientKnownHostsPath =
    if hasPrefix "/" cfg.clientKnownHostsFile
    then cfg.clientKnownHostsFile
    else "~/${cfg.clientKnownHostsFile}";
  clientKnownHostsArgument =
    if lib.hasInfix "\${" clientKnownHostsPath
    then throw "SSH client known-hosts paths must not contain environment expansion syntax."
    else quoteConfigPath (lib.replaceStrings ["%"] ["%%"] clientKnownHostsPath);
in {
  options.modules.services.ssh = {
    trustedHostCAKeys = mkOpt' (attrsOf (submodule ({name, ...}: {
      options = {
        patterns = mkOption {
          type = listOf str;
          description = "Host patterns trusted for this SSH host CA.";
        };
        publicKey = mkOption {
          type = str;
          description = "Public SSH host CA key in authorized_keys format.";
        };
      };
    }))) {} "SSH host CAs trusted by this client.";

    manageClientConfig = mkBoolOpt' false "Whether to manage an SSH config snippet for generated SSH host CA trust.";
    clientKnownHostsFile = mkOpt' str ".ssh/nixi_known_hosts" "Managed known_hosts file for SSH host CA trust.";
    clientConfigFile = mkOpt' str ".ssh/config.d/nixi-host-ca.conf" "Managed SSH client config snippet.";

    userCertificateRenewal = {
      enable = mkBoolOpt' false "Periodically renew locally signed user certificates; disabled keeps activation-only behavior.";
      intervalSeconds = mkOpt' lib.types.ints.positive 86400 "Renewal interval in seconds; choose less than certificate validity.";
      dependencies = mkOpt' (listOf str) [] "Linux service units that must complete before renewal (for example a runtime secret provider).";
    };

    userCertificates = mkOpt' (attrsOf (submodule ({name, ...}: {
      options = {
        required = mkBoolOpt' false "Fail signing when the CA or public key is missing; false preserves best-effort activation.";
        caKeyFile = mkOption {
          type = contracts.runtimeSecretPath;
          description = "Protected runtime private SSH user CA key used noninteractively to sign this certificate. Root-owned when signing runs as root.";
        };
        publicKeyFile = mkOption {
          type = str;
          default = "${config.home.dir}/.ssh/id_ed25519.pub";
          description = "Public key to sign.";
        };
        certificateFile = mkOption {
          type = str;
          default = "${config.home.dir}/.ssh/id_ed25519-cert.pub";
          description = "Certificate file to install.";
        };
        principals = mkOption {
          type = listOf str;
          default = [config.user.name];
          description = "SSH certificate principals.";
        };
        identityPrefix = mkOption {
          type = str;
          default = "${config.user.name}-${name}";
          description = "Prefix for generated certificate identities.";
        };
        validity = mkOption {
          type = str;
          default = "+30d";
          description = "ssh-keygen certificate validity interval.";
        };
        targetUser = mkOption {
          type = str;
          default = config.user.name;
          description = "Owner for generated SSH files.";
        };
        targetGroup = mkOption {
          type = str;
          default = defaultGroup;
          description = "Group for generated SSH files.";
        };
      };
    }))) {} "User SSH certificates to sign during system activation.";
  };

  config = lib.mkMerge [
    {
      assertions =
        mapAttrsToList
        (name: ca: {
          assertion = ca.patterns != [] && ca.publicKey != "";
          message = "modules.services.ssh.trustedHostCAKeys.${name} requires non-empty patterns and publicKey.";
        })
        cfg.trustedHostCAKeys
        ++ [
          {
            assertion = cfg.trustedHostCAKeys == {} || lib.all (path: contracts.relative path || contracts.absolute path) [cfg.clientKnownHostsFile cfg.clientConfigFile];
            message = "SSH client trust file paths must be canonical relative or absolute paths without control characters or backslashes.";
          }
          {
            assertion = contracts.unique (mapAttrsToList (_: cert: cert.certificateFile) cfg.userCertificates);
            message = "SSH user certificate destinations must be distinct; configure certificateFile explicitly for multiple certificates.";
          }
        ]
        ++ mapAttrsToList (name: cert: {
          assertion = lib.all contracts.absolute [cert.caKeyFile cert.publicKeyFile cert.certificateFile] && contracts.principals cert.principals;
          message = "SSH user certificate ${name} requires canonical absolute paths and nonempty principals without commas or control characters.";
        })
        cfg.userCertificates;

      home.file = mkIf (cfg.trustedHostCAKeys != {}) ({
          ${cfg.clientKnownHostsFile} = {
            text = concatStringsSep "\n" (mapAttrsToList renderHostCA cfg.trustedHostCAKeys) + "\n";
          };
        }
        // optionalAttrs cfg.manageClientConfig {
          ${cfg.clientConfigFile} = {
            text = ''
              Host *
                UserKnownHostsFile ${clientKnownHostsArgument} ~/.ssh/known_hosts
            '';
          };
        });

      system.activationScripts = mkIf (cfg.userCertificates != {}) {
        # Runtime secret providers use mkAfter = 1500 on Darwin.
        postActivation.text = lib.mkOrder 1600 userCertificateScript;
      };
    }
    {system.build.nixiUserCertificateRenewal = renewalScript;}
  ];
}
