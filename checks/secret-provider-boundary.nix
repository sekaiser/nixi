{
  nixi,
  lib,
  runCommand,
  ...
}: let
  inputsWithoutSops = builtins.removeAttrs nixi.inputs ["sops-nix"];
  framework =
    nixi
    // {
      inputs = inputsWithoutSops;
      apps = {};
      checks = {};
    };

  outputs = nixi.lib.mkHostFlake {
    inputs =
      inputsWithoutSops
      // {
        self = framework;
        nixi = framework;
      };

    hosts.boundary = import ./fixtures/secret-provider-boundary/host.nix;

    systems = ["aarch64-linux"];
  };
  missingSopsOutputs = nixi.lib.mkHostFlake {
    inputs =
      inputsWithoutSops
      // {
        self = framework;
        nixi = framework;
      };

    hosts.missing-sops = {
      system = "aarch64-linux";
      module = {...}: {
        config = {...}: {
          user = {
            name = "missing-sops";
            home = "/home/missing-sops";
          };
          system.stateVersion = "26.05";
          home.stateVersion = "26.05";

          modules.profiles.homelab-secrets = {
            enable = true;
            defaultSopsFile = "/run/secrets.yaml";
          };
        };
      };
    };

    systems = ["aarch64-linux"];
  };

  host = outputs.nixosConfigurations.boundary;
  missingSopsAssertions = missingSopsOutputs.nixosConfigurations.missing-sops.config.assertions;
  missingSopsMessages =
    map (assertion: assertion.message)
    (builtins.filter (assertion: !assertion.assertion) missingSopsAssertions);
  actual = {
    hasSopsConfig = host.config ? sops;
    k3sTokenFile = host.config.services.k3s.tokenFile;
    tailscaleRuntimeCredential = host.config.systemd.services.tailscaled-autoconnect.serviceConfig.LoadCredential;
    missingSopsMessagePresent =
      builtins.elem
      "modules.profiles.homelab-secrets requires hey.inputs.sops-nix when enabled."
      missingSopsMessages;
  };

  expected = {
    hasSopsConfig = false;
    k3sTokenFile = "/run/secrets/k3s-agent-token";
    tailscaleRuntimeCredential = ["nixi-auth-key:/run/secrets/tailscale-auth-key"];
    missingSopsMessagePresent = true;
  };

  # Model the provider's automatic SSH key defaults without making SOPS a
  # mandatory framework input. These defaults must be explicitly overridden.
  provider = {
    config,
    lib,
    ...
  }: {
    options = {
      services.openssh.enable = lib.mkEnableOption "OpenSSH";
      assertions = lib.mkOption {
        type = lib.types.listOf lib.types.attrs;
        default = [];
      };
      sops = {
        defaultSopsFile = lib.mkOption {type = lib.types.str;};
        secrets = lib.mkOption {
          type = lib.types.attrs;
          default = {};
        };
        age.keyFile = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
        };
        age.sshKeyPaths = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = lib.optional config.services.openssh.enable "/etc/ssh/ssh_host_ed25519_key";
        };
        gnupg.sshKeyPaths = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = lib.optional config.services.openssh.enable "/etc/ssh/ssh_host_rsa_key";
        };
      };
    };
  };
  identities = extra: let
    evaluated = lib.evalModules {
      specialArgs.hey.inputs.sops-nix.nixosModules.sops = provider;
      modules = [
        ../modules/platform/linux/profiles/homelab-secrets.nix
        {
          services.openssh.enable = true;
          modules.profiles.homelab-secrets = {
            enable = true;
            defaultSopsFile = "/fixture/secrets.yaml";
            ageKeyFile = "/fixture/age-identity";
            sshKeyPaths = ["/fixture/host-identity"];
          };
        }
        extra
      ];
    };
  in {
    inherit (evaluated.config.sops.age) keyFile sshKeyPaths;
    gpg = evaluated.config.sops.gnupg.sshKeyPaths;
  };
in
  assert actual == expected;
  assert identities {}
  == {
    keyFile = "/fixture/age-identity";
    sshKeyPaths = [];
    gpg = [];
  };
  assert identities {modules.profiles.homelab-secrets.useHostSshKey = true;}
  == {
    keyFile = null;
    sshKeyPaths = ["/fixture/host-identity"];
    gpg = [];
  };
  assert identities {
    sops.age = {
      keyFile = "/native/age";
      sshKeyPaths = ["/native/ssh"];
    };
    sops.gnupg.sshKeyPaths = ["/native/gpg"];
  }
  == {
    keyFile = "/native/age";
    sshKeyPaths = ["/native/ssh"];
    gpg = ["/native/gpg"];
  };
    runCommand "secret-provider-boundary-check" {
      checked = builtins.toJSON actual;
    } ''
      touch "$out"
    ''
