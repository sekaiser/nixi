{
  systems = ["aarch64-darwin" "x86_64-darwin"];
  package = {
    nixi,
    lib,
    pkgs,
    python3,
    runCommand,
    writeText,
    writeShellScriptBin,
    ...
  }: let
    # Test-only upstream pin. Consumers retain their own SOPS input/version.
    provider = builtins.fetchTree {
      type = "github";
      owner = "Mic92";
      repo = "sops-nix";
      rev = "f1406619a3884cd5c47992a70b8b35c9c0fcb4c9";
      narHash = "sha256-aCWC8ngycU7OdJrU2+Je3qf+1a2ykuBvpPhZT/9tXMc=";
    };
    fakeProvider = writeShellScriptBin "sops-install-secrets" ''
      printf '%s\n' "$@"
    '';
    outputs = nixi.lib.mkHostFlake {
      inputs = {
        self.outPath = ./fixtures/cli-host;
        inherit nixi;
        sops-nix = provider;
      };
      hosts.fixture = {
        system = pkgs.stdenv.hostPlatform.system;
        module = _: {
          imports = [../modules/optional/sops-darwin.nix];
          config = {config, ...}: {
            user = {
              name = "alice";
              home = "/Users/alice";
            };
            home.stateVersion = "26.05";
            system.stateVersion = 6;
            sops = {
              package = fakeProvider;
              validationPackage = (pkgs.callPackage "${provider}/default.nix" {}).sops-install-secrets;
              defaultSopsFile = writeText "synthetic-sops.yaml" "synthetic fixture, no credentials\n";
              validateSopsFiles = false;
              age.keyFile = "/fixture/identity";
              age.sshKeyPaths = [];
              gnupg.sshKeyPaths = [];
              secrets = {
                git = {};
                ca = {mode = "0400";};
                early = {
                  neededForUsers = true;
                  group = "root";
                };
                named.name = "nested/alias";
                explicit.path = "/private/var/lib/consumer/explicit";
              };
              templates.fixture.content = "value=${config.sops.placeholder.git}\n";
              # Upstream's validator indexes placeholders by deployed name.
              placeholder."nested/alias" = "<SOPS:${builtins.hashString "sha256" "named"}:PLACEHOLDER>";
            };
            modules.shell.git = {
              enable = true;
              secrets.fixture.sourceFile = config.sops.secrets.git.path;
            };
            modules.services.ssh.userCertificates.fixture.caKeyFile = config.sops.secrets.ca.path;
          };
        };
      };
    };
    host = outputs.darwinConfigurations.fixture;
    config = host.config;
    readManifest = manifest: builtins.fromJSON (builtins.unsafeDiscardStringContext manifest.text);
    regular = readManifest config.system.build.sops-nix-manifest;
    early = readManifest config.system.build.sops-nix-users-manifest;
    changed = (host.extendModules {modules = [{nixi.sopsDarwin.directory = "/private/var/lib/other-sops";}];}).config;
    invalid = (host.extendModules {modules = [{nixi.sopsDarwin.directory = "/private/var/run/secrets";}];}).config;
    literalKey = (host.extendModules {modules = [{sops.age.keyFile = lib.mkForce /fixture/identity;}];}).config;
    literalSshKey = (host.extendModules {modules = [{sops.age.sshKeyPaths = lib.mkForce [/fixture/ssh-identity];}];}).config;
    storeHome = (host.extendModules {modules = [{sops.gnupg.home = lib.mkForce "${writeText "synthetic-identity" "not a key"}";}];}).config;
    plain =
      (host.extendModules {
        modules = [
          {
            sops.secrets = lib.mkForce {};
            sops.templates = lib.mkForce {};
            modules.shell.git.secrets = lib.mkForce {};
            modules.services.ssh.userCertificates = lib.mkForce {};
          }
        ];
      })
      .config;
    rejects = value: !(builtins.tryEval (builtins.deepSeq value true)).success;
    postActivation = config.system.activationScripts.postActivation.text;
    fixture = writeText "sops-darwin-fixture.json" (builtins.toJSON {
      regular = config.system.build.sops-nix-manifest;
      early = config.system.build.sops-nix-users-manifest;
      activation = builtins.unsafeDiscardStringContext postActivation;
      daemon = builtins.unsafeDiscardStringContext config.launchd.daemons.sops-install-secrets.command;
      earlyDaemon = builtins.unsafeDiscardStringContext config.launchd.daemons.sops-install-secrets-for-users.command;
      # Use the native build-platform shell for the wrapper execution fixture.
      wrapper = pkgs.writeShellScript "native-sops-wrapper" config.sops.package.text;
    });
  in
    assert lib.all (a: a.assertion) config.assertions;
    assert lib.all (a: a.assertion) plain.assertions;
    assert lib.any (a: !a.assertion) invalid.assertions;
    assert rejects literalKey.sops.age.keyFile;
    assert rejects literalSshKey.sops.age.sshKeyPaths;
    assert rejects storeHome.sops.gnupg.home;
    assert regular.secretsMountPoint == "/private/var/lib/nixi-sops/secrets.d";
    assert regular.symlinkPath == "/private/var/lib/nixi-sops/secrets";
    assert early.secretsMountPoint == "/private/var/lib/nixi-sops/secrets-for-users.d";
    assert early.symlinkPath == "/private/var/lib/nixi-sops/secrets-for-users";
    assert config.sops.secrets.named.path == "/private/var/lib/nixi-sops/secrets/nested/alias";
    assert config.sops.secrets.explicit.path == "/private/var/lib/consumer/explicit";
    assert config.sops.secrets.early.path == "/private/var/lib/nixi-sops/secrets-for-users/early";
    assert config.sops.templates.fixture.path == "/private/var/lib/nixi-sops/secrets/rendered/fixture";
    assert changed.sops.secrets.git.path == "/private/var/lib/other-sops/secrets/git";
    assert (readManifest changed.system.build.sops-nix-manifest).symlinkPath == "/private/var/lib/other-sops/secrets";
    assert builtins.hasContext config.system.build.sops-nix-manifest.text;
      runCommand "sops-darwin-check" {
        nativeBuildInputs = [python3];
      } ''
        export PYTHONDONTWRITEBYTECODE=1
        python - ${fixture} <<'PY'
        import json, subprocess, sys
        from pathlib import Path
        fixture = json.loads(Path(sys.argv[1]).read_text())
        regular = json.loads(Path(fixture["regular"]).read_text())
        early = json.loads(Path(fixture["early"]).read_text())
        assert regular["secretsMountPoint"].startswith("/private/var/lib/")
        assert early["secretsMountPoint"].startswith("/private/var/lib/")
        assert not regular["userMode"] and not early["userMode"]
        assert regular["ageKeyFile"] == "/fixture/identity"
        for document in (regular, early):
            for secret in document["secrets"]:
                assert secret["path"].startswith("/private/var/lib/")
                assert Path(secret["sopsFile"]).is_file(), "manifest lost its source dependency"
            for template in document["templates"]:
                assert template["path"].startswith("/private/var/lib/")
                assert Path(template["file"]).is_file(), "manifest lost its template dependency"
        activation = fixture["activation"]
        for consumer in ("/bin/nixi-install-user-file ", "/bin/nixi-ssh-certificate user"):
            assert activation.index(fixture["regular"]) < activation.index(consumer)
            assert activation.index(fixture["early"]) < activation.index(consumer)
        assert fixture["regular"] in fixture["daemon"]
        assert fixture["early"] in fixture["earlyDaemon"]
        # Build-time validation must pass through without attempting root-only
        # directory creation, and preserve every argv element literally.
        arguments = ["-check-mode=manifest", "space path", "$(not-a-shell)"]
        result = subprocess.run([fixture["wrapper"], *arguments], capture_output=True,
                                text=True, check=True, timeout=5)
        assert result.stdout.splitlines() == arguments
        # Runtime mode refuses an unprivileged caller before invoking SOPS.
        # A trailing validation-looking argument must not bypass the preflight.
        for arguments in (["manifest"], ["manifest", "-check-mode=manifest"]):
            result = subprocess.run([fixture["wrapper"], *arguments], capture_output=True,
                                    text=True, timeout=5)
            assert result.returncode != 0 and result.stdout == ""
            assert "requires root" in result.stderr
        PY
        touch "$out"
      '';
}
