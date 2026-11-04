{
  hey,
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (builtins) attrNames dirOf filter isPath replaceStrings;
  inherit (lib) all concatStringsSep escapeShellArg mapAttrs' mapAttrsToList mkIf mkMerge mkOption optional optionals optionalString unique;
  inherit (lib.types) attrsOf bool int lines listOf nullOr oneOf path str submodule;
  inherit (hey.lib) mkBoolOpt;

  cfg = config.modules.shell.git;
  contracts = import "${hey.frameworkDir}/lib/internal/file-contracts.nix" {inherit lib;};
  secretTargets = mapAttrsToList (_: secret: secret.target) cfg.secrets;
  userFileInstaller = pkgs.callPackage "${hey.frameworkDir}/packages/install-user-file.nix" {};
  gitValueType = nullOr (oneOf [bool int path str]);
  # Retain the legacy ordered-section API, but delegate value escaping and
  # serialization to Nixpkgs. New configuration can use programs.git directly.
  renderGitSetting = name: value:
    optionalString (value != null) (lib.removePrefix "[nixi]\n" (lib.generators.toGitINI {
      nixi.${name} =
        if isPath value
        then toString value
        else value;
    }));
  renderGitSettings = settings:
    concatStringsSep "\n"
    (filter (line: line != "") (mapAttrsToList renderGitSetting settings));
  escapeGitSubsection = replaceStrings ["\\" "\""] ["\\\\" "\\\""];
  renderGitSectionHeader = section:
    if section.subsection == null
    then "[${section.name}]"
    else "[${section.name} \"${escapeGitSubsection section.subsection}\"]";
  renderGitEntry = entry: renderGitSetting entry.name entry.value;
  renderGitSection = section: let
    settingsText = renderGitSettings section.settings;
    entriesText = concatStringsSep "\n" (map renderGitEntry section.entries);
    body = concatStringsSep "\n" (filter (text: text != "") [
      settingsText
      entriesText
      section.extraText
    ]);
  in
    concatStringsSep "\n" (filter (text: text != "") [
      (renderGitSectionHeader section)
      body
    ]);
  renderGitInclude = include:
    renderGitSection {
      name =
        if include.condition == null
        then "include"
        else "includeIf";
      subsection = include.condition;
      settings = {};
      entries = [
        {
          name = "path";
          value = include.path;
        }
      ];
      extraText = "";
    };
  renderGitConfig = gitConfig:
    concatStringsSep "\n\n" (filter (text: text != "") (
      (map renderGitInclude gitConfig.includes)
      ++ (map renderGitSection gitConfig.sections)
      ++ gitConfig.extraSections
      ++ optional (gitConfig.extraText != "") gitConfig.extraText
    ));
  renderProfileFile = file:
    if file.source != null
    then {source = file.source;}
    else if file.text != null
    then {text = file.text;}
    else {
      text = let
        rendered = renderGitConfig {
          inherit (file.config) includes sections extraSections extraText;
        };
      in
        if rendered == ""
        then ""
        else rendered + "\n";
    };
  renderedProfileFiles =
    mapAttrs'
    (name: file: {
      name = "git/${name}";
      value = renderProfileFile file;
    })
    cfg.profileFiles;
  nestedProfileParents =
    filter (parent: parent != ".")
    (unique (map dirOf (attrNames cfg.profileFiles)));
  migrateProfileParent = parent: let
    target = "${config.home.configDir}/git/${parent}";
  in ''
    if [ -L ${escapeShellArg target} ]; then
      link_target="$(${pkgs.coreutils}/bin/readlink ${escapeShellArg target})"
      case "$link_target" in
        ${builtins.storeDir}/*-home-manager-files/*)
          run ${pkgs.coreutils}/bin/rm -- ${escapeShellArg target}
          ;;
      esac
    fi
  '';
  secretOwner = config.user.name;
  secretGroup =
    if pkgs.stdenv.hostPlatform.isDarwin
    then "staff"
    else config.users.users.${config.user.name}.group;
  renderPrivateGitSecret = name: secret: let
    target = "${config.home.configDir}/git/${secret.target}";
    receipt = "${cfg.secretTracking.receiptDirectory}/${builtins.hashString "sha256" secret.target}.json";
    tracking = optionalString cfg.secretTracking.enable "--receipt ${escapeShellArg receipt} ";
  in ''
    ${userFileInstaller}/bin/nixi-install-user-file ${tracking}${escapeShellArg secret.sourceFile} ${escapeShellArg target} ${escapeShellArg secretOwner} ${escapeShellArg secretGroup} 0600
  '';
  privateGitSecretActivationScripts =
    mapAttrsToList renderPrivateGitSecret cfg.secrets;
  renderedGitConfig = renderGitConfig {
    inherit (cfg.config) includes sections extraSections extraText;
  };
  staticGitConfig = {
    "git/config" = {
      text = lib.mkOrder 900 (
        if renderedGitConfig == ""
        then ""
        else renderedGitConfig + "\n"
      );
    };
    "gitlint/default.ini" = {
      source = "${hey.assetsDir}/git/gitlint/default.ini";
    };
  };
  profileFileType = submodule {
    options = {
      source = mkOption {
        type = nullOr path;
        default = null;
        description = "Path to a git config snippet.";
      };
      text = mkOption {
        type = nullOr lines;
        default = null;
        description = "Inline git config snippet.";
      };
      config = {
        includes = mkOption {
          type = listOf gitIncludeType;
          default = [];
          description = "Git include/includeIf sections to render into this profile file.";
        };
        sections = mkOption {
          type = listOf gitSectionType;
          default = [];
          description = "Structured Git config sections rendered into this profile file.";
        };
        extraSections = mkOption {
          type = listOf lines;
          default = [];
          description = "Raw complete Git config sections appended to this profile file.";
        };
        extraText = mkOption {
          type = lines;
          default = "";
          description = "Raw Git config text appended to this profile file.";
        };
      };
    };
  };
  secretType = submodule ({name, ...}: {
    options = {
      target = mkOption {
        type = str;
        default = name;
        description = "Path below XDG_CONFIG_HOME/git where the secret file is installed.";
      };
      sourceFile = mkOption {
        type = nullOr contracts.runtimeSecretPath;
        default = null;
        description = "Runtime source file copied to the secret target.";
      };
    };
  });
  gitEntryType = submodule {
    options = {
      name = mkOption {
        type = str;
        description = "Git config key name.";
      };
      value = mkOption {
        type = gitValueType;
        default = null;
        description = "Git config value. Null omits the entry.";
      };
    };
  };
  gitSectionType = submodule {
    options = {
      name = mkOption {
        type = str;
        description = "Git config section name, for example core, user, url, or branch.";
      };
      subsection = mkOption {
        type = nullOr str;
        default = null;
        description = "Optional Git config subsection rendered as [section \"subsection\"].";
      };
      settings = mkOption {
        type = attrsOf gitValueType;
        default = {};
        description = "Single-value Git config keys for this section.";
      };
      entries = mkOption {
        type = listOf gitEntryType;
        default = [];
        description = "Ordered Git config entries. Use this for duplicate keys or order-sensitive sections.";
      };
      extraText = mkOption {
        type = lines;
        default = "";
        description = "Raw text appended inside this section.";
      };
    };
  };
  gitIncludeType = submodule {
    options = {
      condition = mkOption {
        type = nullOr str;
        default = null;
        description = "Optional includeIf condition. Null renders a plain [include] section.";
      };
      path = mkOption {
        type = str;
        description = "Git config include path.";
      };
    };
  };
in {
  options.modules.shell.git = {
    enable = mkBoolOpt false;
    tools = {
      github = mkBoolOpt false;
      githubDashboard = mkBoolOpt false;
      githubActionsCache = mkBoolOpt false;
      githubEco = mkBoolOpt false;
      gitOpen = mkBoolOpt false;
      diffSoFancy = mkBoolOpt false;
      gitCrypt = mkBoolOpt false;
      lazygit = mkBoolOpt false;
      onefetch = mkBoolOpt false;
      gitlint = mkBoolOpt false;
      delta = mkBoolOpt false;
      difftastic = mkBoolOpt false;
    };
    config = {
      includes = mkOption {
        type = listOf gitIncludeType;
        default = [];
        description = "Git include/includeIf sections to render into git/config.";
      };
      sections = mkOption {
        type = listOf gitSectionType;
        default = [];
        description = "Structured Git config sections rendered into git/config.";
      };
      extraSections = mkOption {
        type = listOf lines;
        default = [];
        description = "Raw complete Git config sections appended after structured sections.";
      };
      extraText = mkOption {
        type = lines;
        default = "";
        description = "Raw Git config text appended at the end of git/config.";
      };
    };
    profileFiles = mkOption {
      type = attrsOf profileFileType;
      default = {};
      description = "Additional git config snippets written below XDG_CONFIG_HOME/git.";
    };
    secrets = mkOption {
      type = attrsOf secretType;
      default = {};
      description = "Secret files installed below XDG_CONFIG_HOME/git during activation.";
    };
    secretTracking = {
      enable = mkOption {
        type = bool;
        default = false;
        description = "Opt into private runtime installation receipts and the manual retirement CLI. Removing a declaration never deletes an installed copy.";
      };
      receiptDirectory = mkOption {
        type = contracts.runtimeSecretPath;
        default = "${config.home.stateDir}/nixi/git-secret-copies";
        description = "Private runtime receipts for explicitly tracked Git secret copies. No existing copy is adopted or retired automatically.";
      };
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      assertions = [
        {
          assertion = !cfg.secretTracking.enable || lib.hasPrefix "${config.home.dir}/" cfg.secretTracking.receiptDirectory;
          message = "Git secret tracking receipts must be inside the selected user's home.";
        }
        {
          assertion = !cfg.secretTracking.enable || contracts.disjointPaths ([cfg.secretTracking.receiptDirectory] ++ map (target: "${config.home.configDir}/git/${target}") (secretTargets ++ attrNames cfg.profileFiles ++ ["config"]));
          message = "Git secret tracking receipts must not overlap Git config, secret or profile destinations.";
        }
        {
          assertion = all (secret: secret.sourceFile == null || contracts.absolute secret.sourceFile) (builtins.attrValues cfg.secrets);
          message = "Git secret sourceFile values must be canonical absolute runtime paths.";
        }
        {
          assertion = all contracts.relative (secretTargets ++ attrNames cfg.profileFiles);
          message = "Git secret targets and profile file names must be canonical relative paths without empty, '.' or '..' components, backslashes or control characters.";
        }
        {
          assertion = contracts.disjointPaths (secretTargets ++ attrNames cfg.profileFiles ++ ["config"]);
          message = "Git secret and profile destinations must not overlap each other or the managed config file (including ancestor/descendant paths).";
        }
        {
          assertion =
            all
            (name: let
              file = cfg.profileFiles.${name};
            in
              file.source
              != null
              || file.text != null
              || file.config.includes != []
              || file.config.sections != []
              || file.config.extraSections != []
              || file.config.extraText != "")
            (attrNames cfg.profileFiles);
          message = "Each modules.shell.git.profileFiles entry must set source, text, or config.";
        }
        {
          assertion =
            all
            (name: cfg.secrets.${name}.sourceFile != null)
            (attrNames cfg.secrets);
          message = "Each modules.shell.git.secrets entry must set sourceFile.";
        }
      ];

      user.packages =
        optional cfg.tools.github pkgs.gh
        ++ optional cfg.tools.githubDashboard pkgs.gh-dash
        ++ optional cfg.tools.githubActionsCache pkgs.gh-actions-cache
        ++ optional cfg.tools.githubEco pkgs.gh-eco
        ++ optional cfg.tools.gitOpen pkgs.git-open
        ++ optional cfg.tools.diffSoFancy pkgs.diff-so-fancy
        ++ optionals (cfg.tools.gitCrypt && config.modules.shell.gnupg.enable) [pkgs.git-crypt]
        ++ optional cfg.tools.lazygit pkgs.lazygit
        ++ optional cfg.tools.onefetch pkgs.onefetch
        ++ optional cfg.tools.gitlint pkgs.gitlint
        ++ optional cfg.tools.delta pkgs.delta
        ++ optional cfg.tools.difftastic pkgs.difftastic
        ++ optional cfg.secretTracking.enable userFileInstaller;

      home.configFile = staticGitConfig // renderedProfileFiles;

      # Native Home Manager owns the main config and merges native settings after
      # legacy sections. Includes still retain Home Manager's trailing order.
      home-manager.users.${config.user.name} = {
        programs.git = {
          enable = lib.mkDefault true;
          ignores = lib.mkBefore (lib.splitString "\n" (builtins.readFile "${hey.assetsDir}/git/ignore"));
          attributes = lib.mkBefore (lib.splitString "\n" (builtins.readFile "${hey.assetsDir}/git/attributes"));
        };
        home.activation.migrateGitProfileParents =
          # Never mutate the old generation before collision checks succeed.
          # Keep ordinary file collisions visible; only unlink HM-owned parents.
          config.home-manager.users.${config.user.name}.lib.dag.entryBetween ["linkGeneration"] ["writeBoundary" "checkFilesChanged"]
          (concatStringsSep "\n" (map migrateProfileParent nestedProfileParents));
      };

      system.activationScripts.postActivation.text =
        # Runtime providers (including SOPS on Darwin) use mkAfter = 1500.
        # Consumers must run after decryption, including on the first switch.
        lib.mkOrder 1600 (concatStringsSep "\n" privateGitSecretActivationScripts);

      modules.shell.zsh.rcFiles = mkIf config.modules.shell.zsh.enable ["${hey.assetsDir}/git/aliases.zsh"];
    }
  ]);
}
