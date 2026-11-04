{
  nixi,
  lib,
  pkgs,
  python3,
  zsh,
  runCommand,
  writeText,
  ...
}: let
  outputs = nixi.lib.mkHostFlake {
    inputs = {
      self.outPath = ./fixtures/cli-host;
      inherit nixi;
    };
    hosts = lib.genAttrs ["x86_64-linux" "aarch64-linux" "aarch64-darwin"] (system: {
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
        };
      };
    });
  };
  hosts = builtins.attrValues outputs.nixosConfigurations ++ builtins.attrValues outputs.darwinConfigurations;
  variants = host: let
    extend = settings: host.extendModules {modules = [settings];};
    jdk21 = extend {modules.dev.java.openjdk21.enable = true;};
    jdk25 = extend {modules.dev.java.openjdk25.enable = true;};
    preset = jdk25.extendModules {modules = [{modules.profiles.java-workstation.enable = true;}];};
  in {
    inherit jdk21 jdk25 preset;
    override = jdk25.extendModules {modules = [{modules.dev.java.package = host.pkgs.openjdk21;}];};
    generic = extend {
      modules.dev.java.enable = true;
      modules.dev.java.package = host.pkgs.openjdk21;
    };
    default = extend {modules.dev.java.enable = true;};
    standalonePreset = extend {modules.profiles.java-workstation.enable = true;};
    zsh = preset.extendModules {modules = [{modules.shell.zsh.enable = true;}];};
    disabled = map (value: preset.extendModules {modules = [{modules.dev.java.enable = value;}];}) [false (lib.mkForce false)];
    customHome = preset.extendModules {
      modules = [
        {
          home-manager.users.alice.home.sessionVariables = {
            JAVA_HOME = "/fixture/custom-jdk";
            JDK_HOME = "/fixture/custom-jdk";
          };
        }
      ];
    };
    conflict = extend {
      modules.dev.java.openjdk21.enable = true;
      modules.dev.java.openjdk25.enable = true;
    };
  };
  names = map lib.getName;
  tools = host: with host.pkgs; [checkstyle gradle jdt-language-server maven];
  verifies = host: let
    cases = variants host;
    packages = variant: variant.config.users.users.alice.packages;
    added = variant: lib.sort builtins.lessThan (lib.subtractLists (names (packages host)) (names (packages variant)));
    expected = packages: lib.sort builtins.lessThan (names packages);
    homes = variant: variant.config.home-manager.users.alice.home.sessionVariables;
    globalUnset = variant: lib.all (key: !(variant.config.env ? ${key}) && !(variant.config.environment.variables ? ${key})) ["JAVA_HOME" "JDK_HOME"];
    noAliases = variant: !(lib.any (file: lib.hasSuffix "/dev/java/aliases.zsh" (toString file)) variant.config.modules.shell.zsh.rcFiles);
    minimal = variant: selected:
      added variant
      == expected [selected]
      && variant.config.modules.dev.java.package.drvPath == selected.drvPath
      && globalUnset variant
      && !(homes variant ? JAVA_HOME)
      && !(homes variant ? JDK_HOME)
      && noAliases variant
      && !(variant.config.home.configFile ? "jdks");
    noEffects = variant:
      !variant.config.modules.dev.java.enable
      && added variant == []
      && homes variant == homes host
      && globalUnset variant
      && noAliases variant
      && builtins.attrNames variant.config.home.configFile == builtins.attrNames host.config.home.configFile;
    foreign = (builtins.head cases.disabled).extendModules {
      modules = [
        {
          user.packages = [host.pkgs.maven];
          home.configFile.jdks.text = "consumer-owned inventory";
        }
      ];
    };
  in
    minimal cases.jdk21 host.pkgs.openjdk21
    && minimal cases.jdk25 host.pkgs.openjdk25
    && minimal cases.override host.pkgs.openjdk21
    && minimal cases.generic host.pkgs.openjdk21
    && minimal cases.default host.pkgs.jdk
    && cases.standalonePreset.config.modules.dev.java.enable
    && added cases.preset == expected ([host.pkgs.openjdk25] ++ tools host)
    && globalUnset cases.preset
    && (homes cases.preset).JAVA_HOME == toString host.pkgs.openjdk25
    && (homes cases.preset).JDK_HOME == toString host.pkgs.openjdk25
    && noAliases cases.preset
    && !(cases.preset.config.home.configFile ? "jdks")
    && lib.count (file: lib.hasSuffix "/dev/java/aliases.zsh" (toString file)) cases.zsh.config.modules.shell.zsh.rcFiles == 1
    && lib.all noEffects cases.disabled
    && (homes cases.customHome).JAVA_HOME == "/fixture/custom-jdk"
    && (homes cases.customHome).JDK_HOME == "/fixture/custom-jdk"
    && lib.any (a: !a.assertion && lib.hasInfix "only one legacy Java selector" a.message) cases.conflict.config.assertions
    && added foreign == expected [host.pkgs.maven]
    && foreign.config.home.configFile.jdks.text == "consumer-owned inventory";
  native =
    if pkgs.stdenv.isDarwin
    then outputs.darwinConfigurations.aarch64-darwin
    else outputs.nixosConfigurations.${pkgs.stdenv.hostPlatform.system};
  nativeCases = variants native;
  profiles = writeText "java-policy-profiles.json" (builtins.toJSON (map (name: let
    variant = nativeCases.${name};
    package = variant.config.modules.dev.java.package;
  in {
    inherit name package;
    version = lib.versions.major package.version;
    tools = name == "preset";
    profile = pkgs.buildEnv {
      name = "java-policy-${name}";
      paths = variant.config.users.users.alice.packages;
      pathsToLink = ["/bin"];
      ignoreCollisions = false;
    };
  }) ["jdk21" "jdk25" "preset"]));
in
  assert lib.assertMsg (lib.all verifies hosts) "Java runtime/workstation policy matrix failed";
    runCommand "java-policy-check" {
      nativeBuildInputs = [python3 zsh];
    } ''
      export HOME="$TMPDIR/isolated-home"
      mkdir -p "$HOME"
      python - ${profiles} <<'PY'
      import json, os, subprocess, sys
      from pathlib import Path
      root = Path(os.environ['TMPDIR'])
      source = root / 'NixiPolicyProbe.java'
      source.write_text('class NixiPolicyProbe { public static void main(String[] args) { System.out.print(System.getProperty("java.specification.version")); } }\n')
      for case in json.load(open(sys.argv[1])):
          binary = Path(case['profile']) / 'bin'
          package = Path(case['package'])
          assert (binary / 'java').resolve() == (package / 'bin/java').resolve(), case['name']
          assert (binary / 'javac').resolve() == (package / 'bin/javac').resolve(), case['name']
          for tool in ('mvn', 'gradle', 'jdtls', 'checkstyle'):
              assert (binary / tool).exists() == case['tools'], (case['name'], tool)
          env = {key: value for key, value in os.environ.items()
                 if key not in {'JAVA_TOOL_OPTIONS', 'JDK_JAVA_OPTIONS', '_JAVA_OPTIONS'}}
          env.update(JAVA_HOME=str(package), JDK_HOME=str(package))
          classes = root / ('classes-' + case['name'])
          classes.mkdir()
          result = subprocess.run([str(binary / 'javac'), '-J-Xmx64m', '-d', str(classes), str(source)],
                                  env=env, capture_output=True, text=True, timeout=20)
          assert result.returncode == 0, result.stderr
          result = subprocess.run([str(binary / 'java'), '-Xms16m', '-Xmx64m', '-XX:-UsePerfData',
                                   '-cp', str(classes), 'NixiPolicyProbe'],
                                  env=env, capture_output=True, text=True, timeout=20)
          assert result.returncode == 0 and result.stdout == case['version'], (case['name'], result.stdout, result.stderr)
      print('PASS: JDK 21/25 and workstation profiles compile/run; selected executables and tool separation verified')
      PY
      zsh -n ${../assets/dev/java/aliases.zsh}
      touch "$out"
    ''
