{
  hey,
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) concatStringsSep filterAttrs mapAttrs mapAttrsToList mkIf mkOption optional optionalAttrs optionals;
  inherit (lib.types) attrsOf bool int nullOr str submodule;
  inherit (hey.lib) mkBoolOpt;

  cfg = config.modules.shell.awscli2;
  contracts = import ../../../lib/internal/file-contracts.nix {inherit lib;};

  renderSection = import "${hey.frameworkDir}/lib/internal/aws-ini.nix" {inherit lib;};
  renderProfileSection = name: profile:
    renderSection
    (
      if name == "default"
      then ""
      else "profile "
    )
    name
    {
      region = profile.region;
      output = profile.output;
      sso_session = profile.ssoSession;
      sso_account_id = profile.ssoAccountId;
      sso_role_name = profile.ssoRoleName;
      role_arn = profile.roleArn;
      source_profile = profile.sourceProfile;
      credential_process = profile.credentialProcess;
    }
    profile.extraConfig;
  renderSsoSessionSection = name: session:
    renderSection "sso-session " name {
      sso_start_url = session.startUrl;
      sso_region = session.region;
      sso_registration_scopes = session.registrationScopes;
    }
    session.extraConfig;
  renderSamlAccountSection = name: account:
    renderSection "" name {
      app_id = account.appId;
      url = account.url;
      username = account.username;
      provider = account.provider;
      mfa = account.mfa;
      skip_verify = account.skipVerify;
      timeout = account.timeout;
      aws_urn = account.awsUrn;
      aws_session_duration = account.awsSessionDuration;
      aws_profile = account.awsProfile;
      role_arn = account.roleArn;
      region = account.region;
      saml_cache = account.samlCache;
      disable_remember_device = account.disableRememberDevice;
      disable_session = account.disableSession;
    }
    account.extraConfig;

  profileType = submodule {
    options = {
      region = mkOption {
        type = nullOr str;
        default = cfg.defaultRegion;
        description = "AWS region for this profile.";
      };
      output = mkOption {
        type = nullOr str;
        default = cfg.defaultOutput;
        description = "AWS CLI output format for this profile.";
      };
      ssoSession = mkOption {
        type = nullOr str;
        default = null;
        description = "Name of the sso-session block used by this profile.";
      };
      ssoAccountId = mkOption {
        type = nullOr str;
        default = null;
        description = "AWS account ID used by this SSO profile.";
      };
      ssoRoleName = mkOption {
        type = nullOr str;
        default = null;
        description = "AWS SSO role name used by this profile.";
      };
      roleArn = mkOption {
        type = nullOr str;
        default = null;
        description = "Role ARN for assume-role profiles.";
      };
      sourceProfile = mkOption {
        type = nullOr str;
        default = null;
        description = "Source profile for assume-role profiles.";
      };
      credentialProcess = mkOption {
        type = nullOr str;
        default = null;
        description = "credential_process command for this profile.";
      };
      extraConfig = mkOption {
        type = attrsOf str;
        default = {};
        description = "Trusted raw AWS INI values, overriding structured settings. Keys are validated; values are inserted verbatim and may contain multiline/nested INI syntax. Never put secrets here: this file is stored in the Nix store.";
      };
    };
  };

  ssoSessionType = submodule {
    options = {
      startUrl = mkOption {
        type = str;
        description = "AWS IAM Identity Center start URL.";
      };
      region = mkOption {
        type = nullOr str;
        default = cfg.defaultRegion;
        description = "AWS SSO region.";
      };
      registrationScopes = mkOption {
        type = str;
        default = "sso:account:access";
        description = "AWS SSO registration scopes.";
      };
      extraConfig = mkOption {
        type = attrsOf str;
        default = {};
        description = "Trusted raw AWS sso-session INI values, overriding structured settings. Keys are validated; values are inserted verbatim. Never put secrets here: this file is stored in the Nix store.";
      };
    };
  };

  samlAccountType = submodule {
    options = {
      appId = mkOption {
        type = nullOr str;
        default = null;
        description = "SAML application ID.";
      };
      url = mkOption {
        type = nullOr str;
        default = null;
        description = "SAML login URL.";
      };
      username = mkOption {
        type = nullOr str;
        default = null;
        description = "SAML username. Prefer leaving this in a private overlay if sensitive.";
      };
      usernameFile = mkOption {
        type = nullOr contracts.runtimeSecretPath;
        default = null;
        description = "Runtime file containing the SAML username. The file path may point at a SOPS-managed secret.";
      };
      passwordFile = mkOption {
        type = nullOr contracts.runtimeSecretPath;
        default = null;
        description = "Runtime file containing the SAML password. The file path may point at a SOPS-managed secret.";
      };
      passwordFileFormat = mkOption {
        type = lib.types.enum ["password" "username-password"];
        default = "password";
        description = "Credential file format: one password line, or explicitly two username/password lines. LF and CRLF are supported; meaningful whitespace is preserved. The combined format cannot also set usernameFile.";
      };
      provider = mkOption {
        type = nullOr str;
        default = null;
        description = "saml2aws provider name.";
      };
      mfa = mkOption {
        type = nullOr str;
        default = null;
        description = "saml2aws MFA mode.";
      };
      skipVerify = mkOption {
        type = nullOr bool;
        default = null;
        description = "Whether saml2aws should skip TLS verification.";
      };
      timeout = mkOption {
        type = nullOr int;
        default = null;
        description = "saml2aws timeout in seconds.";
      };
      awsUrn = mkOption {
        type = nullOr str;
        default = null;
        description = "AWS SAML URN.";
      };
      awsSessionDuration = mkOption {
        type = nullOr int;
        default = null;
        description = "AWS session duration in seconds.";
      };
      awsProfile = mkOption {
        type = nullOr str;
        default = null;
        description = "AWS CLI profile that saml2aws writes credentials for.";
      };
      roleArn = mkOption {
        type = nullOr str;
        default = null;
        description = "AWS role ARN to request through saml2aws.";
      };
      region = mkOption {
        type = nullOr str;
        default = cfg.defaultRegion;
        description = "AWS region for this saml2aws account.";
      };
      samlCache = mkOption {
        type = nullOr bool;
        default = null;
        description = "Whether saml2aws should cache SAML assertions.";
      };
      disableRememberDevice = mkOption {
        type = nullOr bool;
        default = null;
        description = "Whether saml2aws should disable remember-device behavior.";
      };
      disableSession = mkOption {
        type = nullOr bool;
        default = null;
        description = "Whether saml2aws should disable session reuse.";
      };
      extraConfig = mkOption {
        type = attrsOf str;
        default = {};
        description = "Trusted raw saml2aws INI values, overriding structured settings. Keys are validated; values are inserted verbatim. Never put secrets here: this file is stored in the Nix store.";
      };
    };
  };

  eksClusterType = submodule ({name, ...}: {
    options = {
      name = mkOption {
        type = str;
        default = name;
        description = "AWS EKS cluster name.";
      };
      profile = mkOption {
        type = str;
        description = "AWS CLI profile used for this EKS cluster.";
      };
      region = mkOption {
        type = nullOr str;
        default = cfg.defaultRegion;
        description = "AWS region for this EKS cluster.";
      };
      kubeContext = mkOption {
        type = nullOr str;
        default = null;
        description = "Kubeconfig context alias for this EKS cluster.";
      };
      bastion = mkOption {
        type = nullOr str;
        default = null;
        description = "Optional UTM VM name used as the bastion for this EKS cluster.";
      };
      vpnService = mkOption {
        type = nullOr str;
        default = null;
        description = "Optional systemd service that must be active on the bastion before cluster access.";
      };
      namespace = mkOption {
        type = nullOr str;
        default = null;
        description = "Optional default Kubernetes namespace for this EKS cluster.";
      };
    };
  });

  renderedConfig = concatStringsSep "\n\n" (
    (mapAttrsToList renderProfileSection cfg.profiles)
    ++ (mapAttrsToList renderSsoSessionSection cfg.ssoSessions)
  );
  renderedSamlConfig = concatStringsSep "\n\n" (
    mapAttrsToList renderSamlAccountSection cfg.saml.accounts
  );
  k9sConfig =
    builtins.replaceStrings
    ["@K9S_STATE_DIR@"]
    ["${config.home.stateDir}/k9s"]
    (builtins.readFile "${hey.assetsDir}/k9s/config.yaml");
in {
  options.modules.shell.awscli2 = {
    enable = mkBoolOpt false;
    defaultRegion = mkOption {
      type = nullOr str;
      default = null;
      description = "Default AWS region applied to generated profiles unless overridden.";
    };
    defaultOutput = mkOption {
      type = nullOr str;
      default = "json";
      description = "Default AWS CLI output format applied to generated profiles unless overridden.";
    };
    profiles = mkOption {
      type = attrsOf profileType;
      default = {};
      description = "AWS CLI profiles to write to AWS_CONFIG_FILE.";
    };
    ssoSessions = mkOption {
      type = attrsOf ssoSessionType;
      default = {};
      description = "AWS IAM Identity Center sso-session blocks to write to AWS_CONFIG_FILE.";
    };
    saml = {
      enable = mkBoolOpt false;
      accounts = mkOption {
        type = attrsOf samlAccountType;
        default = {};
        description = "saml2aws account profiles written to ~/.saml2aws.";
      };
    };
    eks = {
      enable = mkBoolOpt true;
      clusters = mkOption {
        type = attrsOf eksClusterType;
        default = {};
        description = "EKS clusters available to hey eks.";
      };
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.all (account: account.passwordFileFormat != "username-password" || account.usernameFile == null) (builtins.attrValues cfg.saml.accounts);
        message = "SAML username-password format cannot also set usernameFile.";
      }
      {
        assertion = lib.all (key: builtins.match "[a-zA-Z0-9_-]+" key != null) (builtins.attrNames cfg.eks.clusters);
        message = "EKS cluster keys must contain only letters, digits, underscores or hyphens.";
      }
    ];
    user.packages =
      [
        pkgs.awscli2
      ]
      ++ optional cfg.saml.enable pkgs.saml2aws
      ++ optionals cfg.eks.enable [
        pkgs.kubectl
        pkgs.k9s
        pkgs.kubectx
        pkgs.stern
      ];

    home-manager.users.${config.user.name}.home.sessionVariables = {
      AWS_CONFIG_FILE = "${config.home.configDir}/aws/config";
      AWS_SHARED_CREDENTIALS_FILE = "${config.home.configDir}/aws/credentials";
    };

    home.configFile =
      {
        "aws/config" = {
          text =
            if renderedConfig == ""
            then ""
            else renderedConfig + "\n";
        };

        "hey/aws.json" = {
          text = builtins.toJSON {
            awscli2 = {
              schemaVersion = 1;
              profiles = builtins.attrNames cfg.profiles;
              ssoSessions = builtins.attrNames cfg.ssoSessions;
              ssoProfiles = builtins.attrNames (filterAttrs
                (_: profile:
                  (profile.extraConfig.sso_session or profile.ssoSession)
                  != null
                  && (profile.extraConfig.sso_session or profile.ssoSession) != ""
                  || (profile.extraConfig.sso_start_url or "") != "")
                cfg.profiles);
              samlEnabled = cfg.saml.enable;
              eksEnabled = cfg.eks.enable;
              samlAccounts = builtins.attrNames cfg.saml.accounts;
              samlAccountDetails =
                mapAttrs
                (_: account: {
                  inherit (account) usernameFile passwordFile passwordFileFormat;
                  awsProfile = account.extraConfig.aws_profile or account.awsProfile;
                })
                cfg.saml.accounts;
              eksClusters =
                mapAttrs
                (_: cluster: {
                  inherit (cluster) name profile region kubeContext bastion vpnService namespace;
                })
                cfg.eks.clusters;
            };
          };
        };
      }
      // optionalAttrs cfg.eks.enable {
        "k9s/config.yaml" = {
          text = k9sConfig;
        };
        "k9s/aliases.yaml" = {
          source = "${hey.assetsDir}/k9s/aliases.yaml";
        };
        "k9s/hotkeys.yaml" = {
          source = "${hey.assetsDir}/k9s/hotkeys.yaml";
        };
        "k9s/plugins.yaml" = {
          source = "${hey.assetsDir}/k9s/plugins.yaml";
        };
      };

    home.file = mkIf cfg.saml.enable {
      ".saml2aws" = {
        text =
          if renderedSamlConfig == ""
          then ""
          else renderedSamlConfig + "\n";
      };
    };
  };
}
