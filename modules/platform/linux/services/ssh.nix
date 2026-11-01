{
  hey,
  lib,
  config,
  pkgs,
  ...
}: let
  inherit (lib) concatStringsSep escapeShellArg mapAttrsToList mkIf mkOption optional optionalString types;
  inherit (hey.lib) mkBoolOpt' mkOpt';

  cfg = config.modules.services.ssh;
  contracts = import "${hey.frameworkDir}/lib/internal/file-contracts.nix" {inherit lib;};
  quoteConfigPath = import "${hey.frameworkDir}/lib/internal/ssh-config.nix" {inherit lib;};
  certificateTool = pkgs.callPackage "${hey.frameworkDir}/packages/ssh-certificate.nix" {};
  hostCertificatesEnabled = config.services.openssh.enable && cfg.hostCertificates != {};
  certificateConsumer =
    if config.services.openssh.startWhenNeeded
    then "sshd.socket"
    else "sshd.service";
  certificateDependencies =
    optional config.services.openssh.generateHostKeys "sshd-keygen.service"
    ++ optional (config.systemd.services ? sops-install-secrets) "sops-install-secrets.service"
    ++ cfg.hostCertificateDependencies;
  renderHostCertificate = name: cert: ''
    ${certificateTool}/bin/nixi-ssh-certificate host \
      --name=${escapeShellArg name} \
      ${
      if cert.sourceFile != null
      then "--source-file ${escapeShellArg cert.sourceFile}"
      else "--ca-key ${escapeShellArg (
        if cert.caKeyFile == null
        then ""
        else cert.caKeyFile
      )}"
    } \
      --public-key ${escapeShellArg cert.publicKeyFile} \
      --certificate ${escapeShellArg cert.certificateFile} \
      --identity=${escapeShellArg cert.identityPrefix} \
      --principals ${escapeShellArg (builtins.toJSON cert.principals)} \
      --validity=${escapeShellArg cert.validity}
  '';
in {
  options.modules.services.ssh = {
    enable = mkBoolOpt' false "Whether to enable OpenSSH server configuration.";
    passwordAuthentication = mkBoolOpt' true "Whether SSH password authentication is allowed.";
    trustedUserCAKeys = mkOpt' (types.listOf types.str) [] "OpenSSH user CA public keys trusted for certificate login.";
    hostCertificateDependencies = mkOpt' (types.listOf types.str) [] "Additional systemd units required before installing host certificates (for example a runtime secret provider). sshd-keygen and sops-install-secrets, when present, are included automatically.";
    hostCertificateRenewalInterval = mkOpt' types.str "daily" "Systemd calendar interval for refreshing host certificates. Choose an interval shorter than certificate validity.";
    hostCertificates = mkOpt' (types.attrsOf (types.submodule ({name, ...}: {
      options = {
        sourceFile = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Optional pre-signed SSH host certificate to install.";
        };
        caKeyFile = mkOption {
          type = types.nullOr contracts.runtimeSecretPath;
          default = null;
          description = "Optional private SSH host CA key used by the host certificate service.";
        };
        publicKeyFile = mkOption {
          type = types.str;
          default = "/etc/ssh/ssh_host_ed25519_key.pub";
          description = "Host public key to sign.";
        };
        certificateFile = mkOption {
          type = types.str;
          default = "/etc/ssh/ssh_host_ed25519_key-cert.pub";
          description = "Host certificate path used by sshd.";
        };
        principals = mkOption {
          type = types.listOf types.str;
          default = [config.networking.hostName];
          description = "Host certificate principals.";
        };
        identityPrefix = mkOption {
          type = types.str;
          default = "${config.networking.hostName}-${name}";
          description = "Prefix for generated host certificate identities.";
        };
        validity = mkOption {
          type = types.str;
          default = "+52w";
          description = "ssh-keygen host certificate validity interval.";
        };
      };
    }))) {} "OpenSSH host certificates to install or sign before sshd starts and periodically renew.";
  };

  config = mkIf cfg.enable {
    assertions =
      mapAttrsToList
      (name: cert: {
        assertion = cert.sourceFile != null || cert.caKeyFile != null;
        message = "modules.services.ssh.hostCertificates.${name} requires either sourceFile or caKeyFile.";
      })
      cfg.hostCertificates
      ++ [
        {
          assertion = contracts.unique (mapAttrsToList (_: cert: cert.certificateFile) cfg.hostCertificates ++ mapAttrsToList (_: cert: cert.certificateFile) cfg.userCertificates);
          message = "SSH host and user certificate destinations must be distinct; configure certificateFile explicitly for multiple certificates.";
        }
      ]
      ++ mapAttrsToList (name: cert: {
        assertion = lib.all contracts.absolute ([cert.publicKeyFile cert.certificateFile] ++ optional (cert.caKeyFile != null) cert.caKeyFile ++ optional (cert.sourceFile != null) cert.sourceFile) && contracts.principals cert.principals;
        message = "SSH host certificate ${name} requires canonical absolute paths and nonempty principals without commas or control characters.";
      })
      cfg.hostCertificates;

    # Ensure this directory exists and has correct permissions.
    systemd.user.tmpfiles.rules = ["d %h/.config/ssh 700 - - - -"];

    services.openssh = {
      enable = lib.mkDefault true;
      # NixOS already defaults to port 22 and unrestricted AllowUsers. Do not
      # turn those defaults into list merges or conflicting explicit settings.
      settings = {
        PasswordAuthentication = lib.mkDefault cfg.passwordAuthentication;
        PermitRootLogin = lib.mkDefault "prohibit-password";
        GSSAPIAuthentication = lib.mkDefault false;
        TrustedUserCAKeys = mkIf (cfg.trustedUserCAKeys != []) (lib.mkDefault (quoteConfigPath "/etc/ssh/trusted_user_ca_keys.pem"));
      };
      # Deactivate short moduli
      moduliFile = lib.mkOverride 900 (
        pkgs.runCommand "filterModuliFile" {
          nativeBuildInputs = [pkgs.gawk];
        } ''
          awk '$5 >= 3071' "${config.programs.ssh.package}/etc/ssh/moduli" >"$out"
        ''
      );
      extraConfig = optionalString (cfg.hostCertificates != {}) ''
        ${concatStringsSep "\n" (mapAttrsToList (_: cert: "HostCertificate ${quoteConfigPath cert.certificateFile}") cfg.hostCertificates)}
      '';
    };

    environment.etc = mkIf (cfg.trustedUserCAKeys != []) {
      "ssh/trusted_user_ca_keys.pem".text =
        concatStringsSep "\n" cfg.trustedUserCAKeys + "\n";
    };

    systemd.sockets.sshd = mkIf (hostCertificatesEnabled && config.services.openssh.startWhenNeeded) {
      # Certificate/secret services start after basic.target. A socket's default
      # Before=sockets.target would create an ordering cycle through basic.target.
      # Let this socket start late, retaining its normal shutdown ordering.
      unitConfig.DefaultDependencies = false;
      before = ["shutdown.target"];
      conflicts = ["shutdown.target"];
    };

    systemd.services.nixi-ssh-host-certificates = mkIf hostCertificatesEnabled {
      description = "Install and renew SSH host certificates";
      requires = certificateDependencies;
      after = certificateDependencies;
      # For socket activation, install before accepting any connections. Each
      # per-connection daemon then reads the latest atomically replaced cert.
      before = [certificateConsumer];
      requiredBy = [certificateConsumer];
      serviceConfig.Type = "oneshot";
      script = concatStringsSep "\n" (mapAttrsToList renderHostCertificate cfg.hostCertificates);
      # Do not wait for sshd while this unit still orders before it. On first
      # boot sshd is inactive; on renewal an active daemon must reread its cert.
      postStart = optionalString (!config.services.openssh.startWhenNeeded) ''
        if ${pkgs.systemd}/bin/systemctl is-active --quiet sshd.service; then
          ${pkgs.systemd}/bin/systemctl --no-block reload sshd.service
        fi
      '';
    };
    systemd.timers.nixi-ssh-host-certificates = mkIf hostCertificatesEnabled {
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = cfg.hostCertificateRenewalInterval;
        Persistent = true;
      };
    };
  };
}
