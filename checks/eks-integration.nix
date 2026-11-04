{
  nixi,
  lib,
  bash,
  coreutils,
  python3,
  awscli2,
  janet,
  jpm,
  git,
  callPackage,
  writeText,
  runCommand,
  ...
}: let
  deps = callPackage ../packages/hey-janet-deps.nix {inherit janet jpm;};
  supervisor = callPackage ../packages/process-supervisor.nix {};
  runtimePython = callPackage ../packages/hey-python.nix {};
  outputs = nixi.lib.mkHostFlake {
    inputs = {
      self.outPath = ./fixtures/cli-host;
      inherit nixi;
    };
    hosts =
      lib.mapAttrs (platform: system: {
        inherit system;
        module = _: {
          config = {
            user = {
              name = "alice";
              home = "/fixture/alice";
            };
            home.stateVersion = "26.05";
            system.stateVersion =
              if lib.hasSuffix "-darwin" system
              then 6
              else "26.05";
            modules.shell.awscli2 = {
              enable = true;
              profiles = {
                work.ssoSession = "session";
                raw.extraConfig.sso_session = "session";
                legacy.extraConfig.sso_start_url = "https://example.invalid/start";
                disabled = {
                  ssoSession = "session";
                  extraConfig.sso_session = "";
                };
                plain = {};
              };
              ssoSessions.session.startUrl = "https://example.invalid/start";
              saml.accounts.legacy = {
                awsProfile = "original";
                extraConfig.aws_profile = "mapped-profile";
                passwordFile = "/run/secrets/password";
              };
            };
          };
        };
      }) {
        linux = "x86_64-linux";
        linuxArm = "aarch64-linux";
        darwin = "aarch64-darwin";
      };
  };
  linux = outputs.nixosConfigurations.linux;
  hosts = [linux outputs.nixosConfigurations.linuxArm outputs.darwinConfigurations.darwin];
  renderIni = import ../lib/internal/aws-ini.nix {inherit lib;};
  acceptedIni = name: values: extra: (builtins.tryEval (renderIni "profile " name values extra)).success;
  invalidNames = ["" "work profile" "review\n[profile injected]" "review]" "[review" "re\"view" "re'view" "re\\view" "review\tname"];
  invalidKeys = ["" "region\ncredential_process" "region = injected" "region:other" "[profile injected]"];
  invalidValues = ["value\ncredential_process = injected" "value\rinjected" "value\tinjected" (builtins.fromJSON ''"value\u001binjected"'')];
  rejectsStructuredIni = host:
    lib.all (spec: let
      invalidHost = host.extendModules {modules = [{modules.shell.awscli2 = spec.settings;}];};
      text =
        if spec.saml or false
        then invalidHost.config.home.file.".saml2aws".text
        else invalidHost.config.home.configFile."aws/config".text;
    in
      !(builtins.tryEval text).success) [
      {settings.profiles.injected.region = "eu-central-1\ncredential_process = injected";}
      {settings.ssoSessions.injected.startUrl = "https://example.invalid/\nskip_verify = true";}
      {
        saml = true;
        settings.saml = {
          enable = true;
          accounts.injected.username = "fixture\nskip_verify = true";
        };
      }
    ];
  iniFixtures = writeText "aws-ini-fixtures.json" (builtins.toJSON (map (host: let
      checked =
        (host.extendModules {
          modules = [
            {
              modules.shell.awscli2 = {
                profiles = {
                  default.region = "eu-north-1";
                  literal = {
                    region = "eu-central-1";
                    credentialProcess = ''"/fixture/bin with spaces" --literal '$HOME' "quoted"'';
                    extraConfig = {
                      region = "us-west-2";
                      s3 = "\n    max_concurrent_requests = 7\n    addressing_style = path";
                    };
                  };
                };
                saml = {
                  enable = true;
                  accounts.legacy = {
                    username = "fixture@example.invalid";
                    skipVerify = false;
                    timeout = 42;
                  };
                };
              };
            }
          ];
        })
        .config;
    in {
      aws = writeText "aws-config-fixture" checked.home.configFile."aws/config".text;
      saml = writeText "saml-config-fixture" checked.home.file.".saml2aws".text;
    })
    hosts));
  metadata = host: (builtins.fromJSON host.config.home.configFile."hey/aws.json".text).awscli2;
  awsPolicy = host: let
    withSettings = settings: host.extendModules {modules = [settings];};
    bare = withSettings {modules.shell.awscli2.enable = lib.mkForce false;};
    eks = withSettings {
      modules.shell.awscli2.eks = {
        enable = true;
        clusters.fixture.profile = "work";
      };
    };
    saml = withSettings {modules.shell.awscli2.saml.enable = true;};
    disabled = eks.extendModules {modules = [{modules.shell.awscli2.eks.enable = lib.mkForce false;}];};
    foreign = disabled.extendModules {
      modules = [
        {
          user.packages = [host.pkgs.kubectl];
          home.configFile."k9s/config.yaml".text = "synthetic consumer configuration";
        }
      ];
    };
    names = variant: map lib.getName variant.config.users.users.alice.packages;
    added = variant: lib.sort builtins.lessThan (lib.subtractLists (names bare) (names variant));
    expected = packages: lib.sort builtins.lessThan (map lib.getName packages);
    tools = with host.pkgs; [kubectl k9s kubectx stern];
    k9sFiles = variant: lib.filter (lib.hasPrefix "k9s/") (builtins.attrNames variant.config.home.configFile);
    noKubernetes = variant:
      !lib.any (name: builtins.elem name (names variant)) (map lib.getName tools)
      && k9sFiles variant == [];
  in
    !host.config.modules.shell.awscli2.eks.enable
    && !(bare.config.home.configFile ? "aws/config")
    && !(bare.config.home.configFile ? "hey/aws.json")
    && !(bare.config.home.file ? ".saml2aws")
    && !lib.any (name: builtins.elem name (names bare)) (map lib.getName ([host.pkgs.awscli2 host.pkgs.saml2aws] ++ tools))
    && noKubernetes host
    && noKubernetes saml
    && noKubernetes disabled
    && added host == expected [host.pkgs.awscli2]
    && added saml == expected [host.pkgs.awscli2 host.pkgs.saml2aws]
    && added eks == expected ([host.pkgs.awscli2] ++ tools)
    && added disabled == added host
    && !((metadata host).eksEnabled)
    && !((metadata host).samlEnabled)
    && (metadata saml).samlEnabled
    && !((metadata saml).eksEnabled)
    && (metadata eks).eksEnabled
    && !((metadata eks).samlEnabled)
    && (metadata eks).eksClusters.fixture.profile == "work"
    && k9sFiles eks == ["k9s/aliases.yaml" "k9s/config.yaml" "k9s/hotkeys.yaml" "k9s/plugins.yaml"]
    && !(disabled.config.home.file ? ".saml2aws")
    && added foreign == expected [host.pkgs.awscli2 host.pkgs.kubectl]
    && foreign.config.home.configFile."k9s/config.yaml".text == "synthetic consumer configuration"
    && !((metadata foreign).eksEnabled)
    && (builtins.fromJSON host.config.home.configFile."hey/aws.json".text).awscli2.ssoProfiles == ["legacy" "raw" "work"];
  bastionPolicy = host: let
    bastion = host.extendModules {modules = [{modules.profiles.eks-bastion.enable = true;}];};
    disabled = bastion.extendModules {modules = [{modules.shell.awscli2.eks.enable = false;}];};
    names = variant: map lib.getName variant.config.users.users.alice.packages;
    tools = map lib.getName (with host.pkgs; [kubectl k9s kubectx stern]);
  in
    (metadata bastion).eksEnabled
    && (metadata bastion).samlEnabled
    && lib.all (name: builtins.elem name (names bastion)) tools
    && !((metadata disabled).eksEnabled)
    && (metadata disabled).samlEnabled
    && !lib.any (name: builtins.elem name (names disabled)) tools
    && !(disabled.config.home.configFile ? "k9s/config.yaml");
  vpnModule.modules.profiles.eks-bastion = {
    enable = true;
    openvpn = {
      enable = true;
      name = "fixture";
      configFile = ''/fixture/client config "quoted".ovpn'';
      authUserFile = "/fixture/user name ' $(literal)";
      authPasswordFile = ''/fixture/password "quoted"'';
      privateKeyPasswordFile = "/fixture/key password";
    };
  };
  vpn = (linux.extendModules {modules = [vpnModule];}).config;
  delegated =
    (linux.extendModules {
      modules = [vpnModule {modules.profiles.eks-bastion.openvpn.allowUserServiceControl = true;}];
    }).config;
  paths = vpn.modules.profiles.eks-bastion.openvpn;
  userCommands = cfg:
    lib.concatMap (rule: rule.commands)
    (lib.filter (rule: builtins.elem "alice" rule.users) cfg.security.sudo.extraRules);
  sudoCommands = userCommands delegated;
  cliFixtures = writeText "eks-cli-fixtures.json" (builtins.toJSON {
    inherit sudoCommands;
    authOnlyMetadata = lib.listToAttrs (map (host:
      lib.nameValuePair host.pkgs.stdenv.hostPlatform.system (metadata (host.extendModules {
        modules = [
          {
            modules.shell.awscli2.saml = {
              enable = true;
              accounts.interactive = {};
            };
          }
        ];
      })))
    hosts);
    vpnCluster = {
      name = "vpn";
      profile = "work";
      vpnService = "openvpn-${paths.name}.service";
    };
    metadata = lib.genAttrs ["linux" "darwin"] (platform:
      metadata ((
          if platform == "linux"
          then linux
          else outputs.darwinConfigurations.darwin
        )
        .extendModules {
          modules = [
            {
              modules.shell.awscli2 = {
                eks.enable = true;
                saml = {
                  enable = true;
                  accounts = {
                    passwordOnly = {
                      passwordFile = "/fixture/password";
                      # This fixture stores username and password in one file.
                      passwordFileFormat = "username-password";
                    };
                    split = {
                      usernameFile = "/fixture/username";
                      passwordFile = "/fixture/password";
                    };
                    interactive = {};
                  };
                };
                eks.clusters.passwordOnly = {
                  name = "passwordOnly";
                  profile = "passwordOnly";
                };
              };
            }
          ];
        }));
  });
  runtimeDir = "/run/openvpn-fixture";
  invalid = overrides:
    (linux.extendModules {
      modules = [vpnModule {modules.profiles.eks-bastion.openvpn = lib.mapAttrs (_: lib.mkForce) overrides;}];
    })
    .config;
  rejects = overrides: message:
    lib.any (a: !a.assertion && lib.hasInfix message a.message) (invalid overrides).assertions;
  invalidCluster =
    (linux.extendModules {
      modules = [
        {
          modules.shell.awscli2.eks.clusters."../escape" = {
            name = "review";
            profile = "work";
          };
        }
      ];
    })
    .config;
in
  assert lib.assertMsg (lib.all awsPolicy hosts) "AWS CLI/EKS opt-in matrix failed";
  assert lib.assertMsg (lib.all bastionPolicy [linux outputs.nixosConfigurations.linuxArm]) "EKS bastion opt-in/override matrix failed";
  assert lib.all (name: !(acceptedIni name {} {})) invalidNames;
  assert lib.all (key: !(acceptedIni "review" {} {${key} = "value";})) invalidKeys;
  assert lib.all (value: !(acceptedIni "review" {region = value;} {})) invalidValues;
  # Raw overrides must not hide malformed typed fields from validation.
  assert !(acceptedIni "review" {region = "invalid\ninjected";} {region = "valid";});
  assert acceptedIni "work/team:role-1_2@example.invalid" {
    region = "eu-central-1";
    output = null;
  } {};
  assert lib.all rejectsStructuredIni hosts;
  # An inline username is public store content even from private source. A
  # runtime username path belongs only in the runtime manifest, not the INI.
  assert lib.all (host: let
    cfg =
      (host.extendModules {
        modules = [
          {
            modules.shell.awscli2.saml = {
              enable = true;
              accounts.runtime.usernameFile = "/run/secrets/synthetic-username";
            };
          }
        ];
      }).config;
    account = (metadata {config = cfg;}).samlAccountDetails.runtime;
    usernameOption = (host.options.modules.shell.awscli2.saml.accounts.type.getSubOptions []).username;
  in
    account.usernameFile
    == "/run/secrets/synthetic-username"
    && !lib.hasInfix "/run/secrets/synthetic-username" cfg.home.file.".saml2aws".text
    && !lib.hasInfix "username =" cfg.home.file.".saml2aws".text
    && lib.hasInfix "Nix store" usernameOption.description
    && lib.hasInfix "usernameFile" usernameOption.description)
  hosts;
  assert lib.all (host: let
    info = metadata host;
    combined = host.extendModules {
      modules = [{modules.shell.awscli2.saml.accounts.legacy.passwordFileFormat = "username-password";}];
    };
    conflicting = combined.extendModules {
      modules = [{modules.shell.awscli2.saml.accounts.legacy.usernameFile = "/fixture/username";}];
    };
    enabled = metadata (host.extendModules {
      modules = [
        {
          modules.shell.awscli2.saml.enable = true;
          modules.shell.awscli2.eks.enable = false;
        }
      ];
    });
  in
    info.schemaVersion
    == 1
    && info.ssoProfiles
    == ["legacy" "raw" "work"]
    && !info.samlEnabled
    && !info.eksEnabled
    && info.samlAccountDetails.legacy.awsProfile == "mapped-profile"
    && info.samlAccountDetails.legacy.passwordFileFormat == "password"
    && (metadata combined).samlAccountDetails.legacy.passwordFileFormat == "username-password"
    && lib.any (a: !a.assertion && lib.hasInfix "username-password format" a.message) conflicting.config.assertions
    && enabled.samlEnabled
    && !enabled.eksEnabled)
  hosts;
  assert lib.hasInfix ''config "/run/openvpn-fixture/client.conf"'' vpn.services.openvpn.servers.fixture.config;
  assert !lib.hasInfix "/fixture/" vpn.services.openvpn.servers.fixture.config;
  assert lib.all (value: lib.hasInfix (lib.escapeShellArg value) vpn.systemd.services.openvpn-fixture.preStart)
  [paths.configFile paths.authUserFile paths.authPasswordFile paths.privateKeyPasswordFile runtimeDir];
  assert lib.hasInfix "from openvpn_client import main" vpn.systemd.services.openvpn-fixture.preStart;
  assert vpn.systemd.services.openvpn-fixture.serviceConfig.RuntimeDirectory == "openvpn-fixture";
  assert vpn.systemd.services.openvpn-fixture.serviceConfig.RuntimeDirectoryMode == "0700";
  assert userCommands vpn == [];
  assert rejects {authFile = "/fixture/combined";} "mutually exclusive";
  assert lib.any (a: !a.assertion && lib.hasInfix "native hooks" a.message)
  (linux.extendModules {modules = [vpnModule {services.openvpn.servers.fixture.up = "echo unsafe";}];}).config.assertions;
  assert rejects {name = "../escape";} "simple service name";
  assert !(builtins.tryEval (invalid {configFile = "relative";}).modules.profiles.eks-bastion.openvpn.configFile).success;
  assert !(builtins.tryEval (invalid {authPasswordFile = "/fixture/password\ninjected";}).modules.profiles.eks-bastion.openvpn.authPasswordFile).success;
  assert lib.any (a: !a.assertion && lib.hasInfix "EKS cluster keys" a.message) invalidCluster.assertions;
  assert sudoCommands
  == map (action: {
    command = "/run/current-system/sw/bin/systemctl ${action} openvpn-fixture.service";
    options = ["NOPASSWD"];
  }) ["start" "restart" "reset-failed"];
    runCommand "eks-integration-check" {
      src = ../.;
      passthru = {inherit cliFixtures;};
      nativeBuildInputs = [bash coreutils python3 awscli2 janet git];
    } ''
      export PYTHONDONTWRITEBYTECODE=1
      export HOME="$TMPDIR/isolated-home"
      mkdir -p "$HOME"
      export AWS_SHARED_CREDENTIALS_FILE="$HOME/no-credentials"
      export AWS_EC2_METADATA_DISABLED=true
      python - ${iniFixtures} <<'PY'
      import configparser, json, os, subprocess, sys
      for fixture in json.load(open(sys.argv[1])):
          env = dict(os.environ, AWS_CONFIG_FILE=fixture["aws"])
          for profile, key, expected in [
              ("default", "region", "eu-north-1"),
              ("literal", "region", "us-west-2"),
              ("literal", "credential_process", "\"/fixture/bin with spaces\" --literal '$HOME' \"quoted\""),
              ("literal", "s3.max_concurrent_requests", "7"),
              ("literal", "s3.addressing_style", "path"),
              ("work", "sso_session", "session"),
          ]:
              # configure get parses settings only; it never runs credential_process.
              result = subprocess.run(["aws", "configure", "get", key, "--profile", profile],
                                      env=env, capture_output=True, text=True, timeout=10, check=True)
              assert result.stdout.rstrip("\n") == expected, (key, result.stdout)
          parsed = configparser.RawConfigParser()
          parsed.read(fixture["aws"])
          assert parsed.sections() == ["default", "profile disabled", "profile legacy", "profile literal", "profile plain", "profile raw", "profile work", "sso-session session"]
          saml = configparser.RawConfigParser()
          saml.read(fixture["saml"])
          assert saml.sections() == ["legacy"]
          assert dict(saml["legacy"]) == {"aws_profile": "mapped-profile", "skip_verify": "false", "timeout": "42", "username": "fixture@example.invalid"}
      PY
      python "$src/test_tools/test_openvpn_credentials.py"
      # Synthetic descriptor/permission and parser tests; root/systemd behavior
      # still requires a native Linux VM acceptance run.
      python "$src/test_tools/test_openvpn_client.py"
      export JANET_PATH="${deps}/lib"
      export JANET_TREE="${deps}"
      export HEY_PROCESS_SUPERVISOR="${supervisor}/bin/nixi-process-supervisor"
      export HEY_RUNTIME_PYTHON="${runtimePython}/bin/python3"
      export NIXI_EKS_FIXTURES="${cliFixtures}"
      python "$src/test_tools/run_cli_tests.py" \
        test_eks_nix_generated_metadata_and_sudo_policy \
        test_eks_login_selects_provider_and_rejects_unknown_or_ambiguous_names \
        test_eks_doctor_only_requires_enabled_authentication_tools \
        test_eks_nullable_metadata_and_invalid_types
      touch "$out"
    ''
