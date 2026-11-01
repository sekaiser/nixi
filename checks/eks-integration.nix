{
  nixi,
  lib,
  bash,
  coreutils,
  python3,
  awscli2,
  writeText,
  runCommand,
  ...
}: let
  outputs = nixi.lib.mkHostFlake {
    inputs = {
      self.outPath = ./fixtures/cli-host;
      inherit nixi;
    };
    hosts = lib.genAttrs ["linux" "darwin"] (platform: {
      system =
        if platform == "linux"
        then "x86_64-linux"
        else "aarch64-darwin";
      module = _: {
        config = {
          user = {
            name = "alice";
            home = "/fixture/alice";
          };
          home.stateVersion = "26.05";
          system.stateVersion =
            if platform == "linux"
            then "26.05"
            else 6;
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
    });
  };
  linux = outputs.nixosConfigurations.linux;
  hosts = [linux outputs.darwinConfigurations.darwin];
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
  paths = vpn.modules.profiles.eks-bastion.openvpn;
  sudoCommands =
    lib.concatMap (rule: rule.commands)
    (lib.filter (rule: builtins.elem "alice" rule.users) vpn.security.sudo.extraRules);
  cliFixtures = writeText "eks-cli-fixtures.json" (builtins.toJSON {
    inherit sudoCommands;
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
  # Exercise the evaluated preStart on the native runner, with dummy secrets.
  # Do not build Linux executables on Darwin or touch /run.
  script = writeText "openvpn-prestart-fixture" (lib.replaceStrings
    [
      "${linux.pkgs.coreutils}/bin/install"
      "${linux.pkgs.python3}/bin/python"
      (lib.escapeShellArg paths.authUserFile)
      (lib.escapeShellArg paths.authPasswordFile)
      (lib.escapeShellArg "${runtimeDir}/auth-user-pass")
      (lib.escapeShellArg runtimeDir)
    ]
    [
      "${coreutils}/bin/install"
      "${python3}/bin/python"
      ''"$FIXTURE_ROOT/user name"''
      ''"$FIXTURE_ROOT/password file"''
      ''"$FIXTURE_ROOT/runtime/auth-user-pass"''
      ''"$FIXTURE_ROOT/runtime"''
    ]
    (builtins.unsafeDiscardStringContext vpn.systemd.services.openvpn-fixture.preStart));
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
    && info.eksEnabled
    && info.samlAccountDetails.legacy.awsProfile == "mapped-profile"
    && info.samlAccountDetails.legacy.passwordFileFormat == "password"
    && (metadata combined).samlAccountDetails.legacy.passwordFileFormat == "username-password"
    && lib.any (a: !a.assertion && lib.hasInfix "username-password format" a.message) conflicting.config.assertions
    && enabled.samlEnabled
    && !enabled.eksEnabled)
  hosts;
  assert lib.hasInfix ''config "/fixture/client config \"quoted\".ovpn"'' vpn.services.openvpn.servers.fixture.config;
  assert lib.hasInfix ''auth-user-pass "/run/openvpn-fixture/auth-user-pass"'' vpn.services.openvpn.servers.fixture.config;
  assert lib.hasInfix ''askpass "/fixture/key password"'' vpn.services.openvpn.servers.fixture.config;
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
      nativeBuildInputs = [bash coreutils python3 awscli2];
      # Keep the helper referenced after stripping foreign executable contexts.
      helper = lib.fileset.toSource {
        root = ../tools;
        fileset = lib.fileset.unions [../tools/openvpn_credentials.py ../tools/runtime_input.py];
      };
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
      export FIXTURE_ROOT="$TMPDIR/credentials with spaces"
      mkdir -p "$FIXTURE_ROOT"
      printf '%s' 'fixture-user' > "$FIXTURE_ROOT/user name"
      printf '%s' 'fixture-password' > "$FIXTURE_ROOT/password file"
      bash -eu ${script}
      printf 'fixture-user\nfixture-password\n' > expected
      cmp expected "$FIXTURE_ROOT/runtime/auth-user-pass"
      test "$(stat -c '%a' "$FIXTURE_ROOT/runtime/auth-user-pass")" = 400
      test "$(stat -c '%a' "$FIXTURE_ROOT/runtime")" = 700
      printf 'invalid\nsecond line\n' > "$FIXTURE_ROOT/password file"
      if bash -eu ${script}; then
        echo 'Invalid credentials unexpectedly accepted' >&2
        exit 1
      fi
      cmp expected "$FIXTURE_ROOT/runtime/auth-user-pass"
      touch "$out"
    ''
