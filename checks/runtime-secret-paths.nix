{
  nixi,
  lib,
  runCommand,
  writeText,
  ...
}: let
  contracts = import ../lib/internal/file-contracts.nix {inherit lib;};
  synthetic = writeText "synthetic-public-input" "Not a key or credential.\n";
  invalid = [
    ./fixtures/cli-host/flake.nix
    "${synthetic}"
    (builtins.unsafeDiscardStringContext "${synthetic}")
    builtins.storeDir
    "relative"
    "/run/../secret"
    "/run//secret"
    "/run/secret\n"
    "/run/secret\\file"
    ""
  ];
  host = system: let
    darwin = lib.hasSuffix "darwin" system;
    outputs = nixi.lib.mkHostFlake {
      inputs = {
        self.outPath = ./fixtures/cli-host;
        inherit nixi;
      };
      hosts.fixture = {
        inherit system;
        module = _: {
          config = {
            user.name = "alice";
            user.home =
              if darwin
              then "/Users/alice"
              else "/home/alice";
            home.stateVersion = "26.05";
            system.stateVersion =
              if darwin
              then 6
              else "26.05";
            hey.enable = false;
          };
        };
      };
    };
  in
    outputs.${
      if darwin
      then "darwinConfigurations"
      else "nixosConfigurations"
    }.fixture;
  linux = host "x86_64-linux";
  darwin = host "aarch64-darwin";
  nested = option: field: (option.type.getSubOptions []).${field}.type;
  sharedTypes = host:
    with host.options.modules; [
      (nested shell.git.secrets "sourceFile")
      (nested services.ssh.userCertificates "caKeyFile")
      (nested shell.awscli2.saml.accounts "usernameFile")
      (nested shell.awscli2.saml.accounts "passwordFile")
    ];
  types =
    sharedTypes linux
    ++ sharedTypes darwin
    ++ (with linux.options.modules;
      [
        (nested services.ssh.hostCertificates "caKeyFile")
        services.tailscale.keyFile.type
        services.k3s-agent.tokenFile.type
        services.k3s-server.tokenFile.type
        services.k3s-server.agentTokenFile.type
        profiles.homelab-secrets.ageKeyFile.type
      ]
      ++ map (name: profiles.eks-bastion.openvpn.${name}.type) [
        "configFile"
        "authFile"
        "authUserFile"
        "authPasswordFile"
        "privateKeyPasswordFile"
      ]);
  validType = type:
    lib.all type.check ["/run/secrets/fixture" "/private/var/lib/secret with spaces"]
    && lib.all (value: !type.check value) invalid;
  rejects = value: !(builtins.tryEval (builtins.deepSeq value true)).success;
  gitSource = host: value:
    (host.extendModules {
      modules = [
        {
          modules.shell.git = {
            enable = true;
            secrets.fixture.sourceFile = value;
          };
        }
      ];
    }).config.modules.shell.git.secrets.fixture.sourceFile;
in
  assert lib.all validType types;
  assert lib.all (value: rejects (contracts.requireRuntimeSecretPath value)) invalid;
  assert contracts.requireRuntimeSecretPath null == null;
  assert contracts.requireRuntimeSecretPath "/run/secrets/fixture" == "/run/secrets/fixture";
  assert linux.options.modules.profiles.homelab-secrets.sshKeyPaths.type.check ["/run/secrets/ssh"];
  assert lib.all (value:
    rejects
    (linux.extendModules {
      modules = [{modules.profiles.homelab-secrets.sshKeyPaths = [value];}];
    }).config.modules.profiles.homelab-secrets.sshKeyPaths)
  invalid;
  assert lib.all (host: lib.all (value: rejects (gitSource host value)) invalid) [linux darwin];
  # Public input references retain Nix context and remain permitted.
  assert (nested linux.options.modules.services.ssh.hostCertificates "sourceFile").check "${synthetic}";
  assert lib.all (host: (nested host.options.modules.services.ssh.userCertificates "publicKeyFile").check "${synthetic}") [linux darwin];
  assert contracts.disjointPaths ["team" "teammate/config" "config"];
  assert contracts.disjointPaths ["team/a" "team/b"];
  assert lib.all (paths: !contracts.disjointPaths paths) [
    ["team" "team"]
    ["team" "team/config"]
    ["team/config" "team"]
    ["config" "config/secret"]
  ];
    runCommand "runtime-secret-paths-check" {} ''
      touch "$out"
    ''
