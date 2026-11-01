{
  nixi,
  lib,
  runCommand,
  stdenv,
  openssh,
  coreutils,
  writeShellScript,
  writeText,
  python3,
  ...
}: let
  outputs = nixi.lib.mkHostFlake {
    inputs = {
      self.outPath = ./fixtures/cli-host;
      inherit nixi;
    };
    hosts.server = {
      system = "x86_64-linux";
      module = _: {
        config = {
          user = {
            name = "alice";
            home = "/home/alice";
          };
          home.stateVersion = "26.05";
          system.stateVersion = "26.05";
          modules.services.ssh = {
            enable = true;
            hostCertificates.fixture.caKeyFile = "/run/secrets/host-ca";
            hostCertificateDependencies = ["fixture-secrets.service"];
            userCertificates.fixture.caKeyFile = "/run/secrets/user-ca";
          };
          systemd.services.fixture-secrets.serviceConfig.Type = "oneshot";
          modules.shell.zsh.enable = true;
          modules.shell.git = {
            enable = true;
            secrets.fixture.sourceFile = "/run/secrets/git";
          };
        };
      };
    };
  };
  config = outputs.nixosConfigurations.server.config;
  service = config.systemd.services.nixi-ssh-host-certificates;
  activation = config.system.activationScripts.postActivation.text;
  socketConfig =
    (outputs.nixosConfigurations.server.extendModules {
      modules = [{services.openssh.startWhenNeeded = true;}];
    })
    .config;
  socketService = socketConfig.systemd.services.nixi-ssh-host-certificates;
  renewalConfig =
    (outputs.nixosConfigurations.server.extendModules {
      modules = [
        {
          modules.services.ssh = {
            userCertificates.fixture.required = true;
            userCertificateRenewal = {
              enable = true;
              intervalSeconds = 3600;
              dependencies = ["fixture-secrets.service"];
            };
          };
        }
      ];
    })
    .config;
  darwin = nixi.lib.mkHostFlake {
    inputs = {
      self.outPath = ./fixtures/cli-host;
      inherit nixi;
    };
    hosts.client = {
      system = "aarch64-darwin";
      module = _: {
        config = {
          user = {
            name = "alice";
            home = "/Users/alice";
          };
          home.stateVersion = "26.05";
          system.stateVersion = 6;
          modules.services.ssh = {
            userCertificates.fixture.caKeyFile = "/var/run/user-ca";
            userCertificateRenewal = {
              enable = true;
              intervalSeconds = 3600;
            };
          };
        };
      };
    };
  };
  darwinRenewal = darwin.darwinConfigurations.client.config.launchd.daemons.nixi-ssh-user-certificates.serviceConfig;
  native =
    (nixi.lib.mkHostFlake {
      inputs = {
        self.outPath = ./fixtures/cli-host;
        inherit nixi;
      };
      hosts.fixture = {
        system = stdenv.hostPlatform.system;
        module = _: {
          config = {
            user =
              {
                name = "fixture";
                home =
                  if stdenv.isDarwin
                  then "/Users/fixture"
                  else "/home/fixture";
              }
              # This synthetic account bypasses the primary-user profile;
              # supply its group too (NixOS otherwise leaves it empty).
              // lib.optionalAttrs (!stdenv.isDarwin) {group = "users";};
            home.stateVersion = "26.05";
            system.stateVersion =
              if stdenv.isDarwin
              then 6
              else "26.05";
            modules.services.ssh.userCertificates.first.caKeyFile = "/nixi-fixture-missing-user-ca";
            modules.services.ssh.userCertificates.second.caKeyFile = "/nixi-fixture-missing-second-ca";
            modules.services.ssh.userCertificates.second.certificateFile = "/tmp/nixi-fixture-second-cert.pub";
          };
        };
      };
    })
    .${
      if stdenv.isDarwin
      then "darwinConfigurations"
      else "nixosConfigurations"
    }
    .fixture;
  requiredNative = native.extendModules {modules = [{modules.services.ssh.userCertificates.first.required = true;}];};
  rejected = module: needle: let
    candidate = (outputs.nixosConfigurations.server.extendModules {modules = [module];}).config;
  in
    lib.any (item: !item.assertion && lib.hasInfix needle item.message) candidate.assertions;
  contracts = import ../lib/internal/file-contracts.nix {inherit lib;};
  successNative = native.extendModules {
    modules = [
      {
        modules.services.ssh.userCertificates = lib.mkForce {
          fixture = {
            caKeyFile = "/nixi-fixture/ca";
            publicKeyFile = "/nixi-fixture/key.pub";
            certificateFile = "/nixi-fixture/installed-cert.pub";
            targetUser = "nixi-fixture-user";
            targetGroup = "nixi-fixture-group";
            principals = ["fixture-principal"];
            required = true;
          };
        };
      }
    ];
  };
  # Exercise generated signing and the real installer as the build user. Only
  # fixture paths/identity and the privileged staging root are substituted.
  successScript = writeShellScript "fixture-user-certificate-signing" (lib.replaceStrings
    [
      "/nixi-fixture/"
      "nixi-fixture-user"
      "nixi-fixture-group"
      "nixi-ssh-certificate user"
    ]
    ["\"$TMPDIR\"/" "\"$fixture_user\"" "\"$fixture_group\"" ''nixi-ssh-certificate user --runtime-directory "$TMPDIR"'']
    successNative.config.system.build.nixiUserCertificateRenewal.text);
  certificatePath = ''/fixture/cert directory/"quoted" #100%.pub'';
  hostParserConfig =
    (outputs.nixosConfigurations.server.extendModules {
      modules = [
        {
          modules.services.ssh.hostCertificates.fixture.certificateFile = certificatePath;
        }
      ];
    })
    .config
    .services
    .openssh
    .extraConfig;
  clientPath = ''.ssh/trust directory/"quoted" #100%.hosts'';
  clientParserConfigs = map (host:
    (host.extendModules {
      modules = [
        {
          modules.services.ssh = {
            trustedHostCAKeys.fixture = {
              patterns = ["*.example.invalid"];
              publicKey = "fixture-public-key";
            };
            manageClientConfig = true;
            clientKnownHostsFile = clientPath;
          };
        }
      ];
    })
    .config
    .home
    .file
    .".ssh/config.d/nixi-host-ca.conf"
    .text)
  [outputs.nixosConfigurations.server darwin.darwinConfigurations.client];
  parserFixtures = writeText "ssh-parser-fixtures.json" (builtins.toJSON {
    inherit certificatePath clientPath clientParserConfigs;
    # Parse foreign-platform settings with the native parser; no subsystem is run.
    hostParserConfig = builtins.unsafeDiscardStringContext hostParserConfig;
  });
  quotePath = import ../lib/internal/ssh-config.nix {inherit lib;};
  literalLabel =
    (native.extendModules {
      modules = [
        {
          modules.services.ssh.userCertificates = lib.mkForce {
            "fixture-$(printf UNEXPECTED_LABEL_EXPANSION >&2)".caKeyFile = "/nixi-fixture-missing-ca";
          };
        }
      ];
    })
    .config
    .system
    .build
    .nixiUserCertificateRenewal;
in
  assert !(builtins.tryEval (quotePath "bad\npath")).success;
  assert !(builtins.tryEval (quotePath "")).success;
  assert lib.all (value: !(contracts.relative value)) ["" "/absolute" "../outside" "nested/../outside" "a//b" "a/./b" "a/" "a\\b" "a\nb"];
  assert contracts.relative "profiles/work.conf";
  assert !contracts.absolute "/a/../b" && contracts.absolute "/tmp/certificate.pub";
  assert !contracts.principals [] && !contracts.principals ["alice,bob"] && contracts.principals ["alice" "bob"];
  assert rejected {modules.shell.git.secrets.fixture.target = "../outside";} "canonical relative";
  assert !(builtins.tryEval
    (outputs.nixosConfigurations.server.extendModules {
      modules = [{modules.shell.git.secrets.fixture.sourceFile = lib.mkForce "relative";}];
    }).config.modules.shell.git.secrets.fixture.sourceFile).success;
  assert rejected {
    modules.services.ssh = {
      trustedHostCAKeys.fixture = {
        patterns = ["*.example.invalid"];
        publicKey = "fixture-public-key";
      };
      clientKnownHostsFile = "../escape";
    };
  } "SSH client trust file paths";
  assert !(builtins.tryEval
    (outputs.nixosConfigurations.server.extendModules {
      modules = [
        {
          modules.services.ssh = {
            trustedHostCAKeys.fixture = {
              patterns = ["*.example.invalid"];
              publicKey = "fixture-public-key";
            };
            manageClientConfig = true;
            clientKnownHostsFile = ".ssh/\${HOME}/hosts";
          };
        }
      ];
    })
    .config
    .home
    .file
    .".ssh/config.d/nixi-host-ca.conf"
    .text)
  .success;
  assert rejected {
    modules.shell.git.secrets.second = {
      sourceFile = "/run/secrets/second";
      target = "fixture";
    };
  } "destinations must not overlap";
  assert rejected {modules.shell.git.secrets.fixture.target = "config";} "destinations must not overlap";
  assert rejected {modules.shell.git.profileFiles."fixture/config".text = "[synthetic]\n";} "destinations must not overlap";
  assert rejected {
    modules.shell.git = {
      secrets.fixture.target = "team/secret";
      profileFiles.team.text = "[synthetic]\n";
    };
  } "destinations must not overlap";
  assert rejected {modules.shell.git.secrets.fixture.target = "config/secret";} "destinations must not overlap";
  assert rejected {modules.services.ssh.userCertificates.second.caKeyFile = "/run/secrets/second-ca";} "user certificate destinations must be distinct";
  assert rejected {modules.services.ssh.hostCertificates.second.caKeyFile = "/run/secrets/second-ca";} "host and user certificate destinations must be distinct";
  assert rejected {modules.services.ssh.userCertificates.fixture.principals = lib.mkForce [];} "nonempty principals";
  assert !(config.systemd.timers ? nixi-ssh-user-certificates);
  assert renewalConfig.systemd.timers.nixi-ssh-user-certificates.timerConfig.OnUnitActiveSec == "3600s";
  assert renewalConfig.systemd.services.nixi-ssh-user-certificates.requires == ["fixture-secrets.service"];
  assert lib.hasInfix "--required" renewalConfig.system.activationScripts.postActivation.text;
  assert darwinRenewal.StartInterval == 3600 && darwinRenewal.RunAtLoad;
  assert darwinRenewal.UserName == "root" && builtins.length darwinRenewal.ProgramArguments == 1;
  assert lib.all (unit: builtins.elem unit service.requires && builtins.elem unit service.after) ["sshd-keygen.service" "fixture-secrets.service"];
  assert builtins.elem "sshd.service" service.before && builtins.elem "sshd.service" service.requiredBy;
  assert service.serviceConfig.Type == "oneshot";
  assert !lib.hasInfix "skipping" service.script;
  assert lib.hasInfix "--no-block reload sshd.service" service.postStart;
  assert config.systemd.timers.nixi-ssh-host-certificates.timerConfig.OnCalendar == "daily";
  assert lib.hasInfix "nixi-ssh-certificate user" activation;
  assert !lib.hasInfix "/bin/cp " activation;
  assert !lib.hasInfix "install -d -m 0700 -o" activation;
  assert !lib.hasInfix "/run/secrets/host-ca" activation;
  assert socketService.before == ["sshd.socket"];
  assert socketService.requiredBy == ["sshd.socket"];
  assert socketService.postStart == "";
  assert !socketConfig.systemd.sockets.sshd.unitConfig.DefaultDependencies;
  assert builtins.elem "shutdown.target" socketConfig.systemd.sockets.sshd.before;
    runCommand "ssh-certificate-lifecycle-check" {nativeBuildInputs = [openssh coreutils python3];} ''
      export PYTHONDONTWRITEBYTECODE=1
      if ! ${literalLabel} > literal-label.log 2> literal-label.err; then
        cat literal-label.err >&2
        exit 1
      fi
      test ! -s literal-label.err
      grep -Fq 'fixture-$(printf UNEXPECTED_LABEL_EXPANSION >&2)' literal-label.log
      python - ${parserFixtures} <<'PY'
      import json, os, pwd, shutil, subprocess, sys, tempfile
      from pathlib import Path
      data = json.load(open(sys.argv[1]))
      def run(args):
          return subprocess.run(args, capture_output=True, text=True, timeout=10, check=True)
      def config_lines(output):
          # OpenSSH versions differ in keyword capitalization. Keep path/value
          # spelling unchanged, including spaces, quotes and literal percent.
          return {key.lower() + separator + value for line in output.splitlines()
                  for key, separator, value in [line.partition(" ")]}
      with tempfile.TemporaryDirectory() as directory:
          root = Path(directory)
          run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(root / "ca")])
          run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(root / "key")])
          run(["ssh-keygen", "-q", "-s", str(root / "ca"), "-h", "-I", "fixture", "-n", "fixture.example.invalid", "-V", "+1h", str(root / "key.pub")])
          certificate = data["certificatePath"].replace("/fixture/", directory + "/")
          Path(certificate).parent.mkdir()
          shutil.copyfile(root / "key-cert.pub", certificate)
          server = root / "sshd_config"
          server.write_text(data["hostParserConfig"].replace("/fixture/", directory + "/"))
          parsed = run(["sshd", "-T", "-f", str(server), "-h", str(root / "key")]).stdout
          assert "hostcertificate " + certificate in config_lines(parsed), parsed
          for content in data["clientParserConfigs"]:
              client = root / "ssh_config"
              client.write_text(content)
              parsed = run(["ssh", "-G", "-F", str(client), "fixture.example.invalid"]).stdout
              home = pwd.getpwuid(os.getuid()).pw_dir
              expected = "userknownhostsfile " + home + "/" + data["clientPath"] + " " + home + "/.ssh/known_hosts"
              assert expected in config_lines(parsed), parsed
      PY
      ${native.config.system.build.nixiUserCertificateRenewal} > optional.log 2>&1
      grep -q 'for second is unavailable' optional.log
      status=0
      ${requiredNative.config.system.build.nixiUserCertificateRenewal} > required.log 2>&1 || status=$?
      test "$status" = 3
      if grep -q 'for second is unavailable' required.log; then
        echo "Required certificate failure did not stop subsequent signing" >&2
        exit 1
      fi
      export fixture_user="$(id -un)" fixture_group="$(id -gn)"
      chmod 700 "$TMPDIR"
      ssh-keygen -q -t ed25519 -N "" -f "$TMPDIR/ca"
      ssh-keygen -q -t ed25519 -N "" -f "$TMPDIR/key"
      ${successScript}
      ssh-keygen -L -f "$TMPDIR/installed-cert.pub" > certificate.txt
      grep -q 'fixture-principal' certificate.txt
      grep -q 'Valid: from' certificate.txt
      ca_fingerprint="$(ssh-keygen -lf "$TMPDIR/ca.pub" | cut -d ' ' -f 2)"
      grep -Fq "$ca_fingerprint" certificate.txt
      cp "$TMPDIR/installed-cert.pub" "$TMPDIR/first-cert.pub"
      sleep 1
      ${successScript}
      if cmp -s "$TMPDIR/first-cert.pub" "$TMPDIR/installed-cert.pub"; then
        echo "Certificate was not renewed" >&2
        exit 1
      fi
      cp "$TMPDIR/installed-cert.pub" "$TMPDIR/good-cert.pub"
      printf '%s\n' invalid-public-key > "$TMPDIR/key.pub"
      if ${successScript}; then
        echo "Invalid public key unexpectedly signed" >&2
        exit 1
      fi
      cmp "$TMPDIR/good-cert.pub" "$TMPDIR/installed-cert.pub"
      touch "$out"
    ''
