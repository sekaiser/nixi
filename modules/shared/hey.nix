{
  config,
  hey,
  lib,
  pkgs,
  ...
}: let
  inherit (builtins) listToAttrs match toJSON;
  inherit (lib) flatten groupBy mapAttrsToList mkAfter mkBefore mkEnableOption mkIf mkOption nameValuePair optionals;
  inherit (lib.types) attrs attrsOf bool listOf lines package str submodule;

  hookFilename = name:
    if (match "^[0-9]{2}-.+" name) == null
    then "50-${name}"
    else name;

  janet = pkgs.unstable.janet;
  processSupervisor = pkgs.callPackage "${hey.frameworkDir}/packages/process-supervisor.nix" {};
  heyJanetDeps = pkgs.callPackage "${hey.frameworkDir}/packages/hey-janet-deps.nix" {
    inherit janet;
    jpm = pkgs.unstable.jpm;
  };
  heyJanetLib = pkgs.callPackage "${hey.frameworkDir}/packages/hey-janet-lib.nix" {
    heyRuntimeDir = hey.runtimeDir;
  };
  heyPackage = pkgs.callPackage "${hey.frameworkDir}/packages/hey.nix" {
    inherit heyJanetDeps heyJanetLib janet processSupervisor;
    heyDir = hey.dir;
    heyBinDir = hey.binDir;
  };

  commandModule = submodule {
    options = {
      description = mkOption {
        type = str;
        default = "";
        description = "Short command description for help, completion, and checks.";
      };

      aliases = mkOption {
        type = listOf str;
        default = [];
        description = "Alternative top-level names for this command.";
      };

      generated = mkOption {
        type = bool;
        default = false;
        description = "Whether this command is generated or dispatches outside hey.d.";
      };

      subcommands = mkOption {
        type = attrsOf (submodule {
          options.description = mkOption {
            type = str;
            default = "";
            description = "Short subcommand description.";
          };
        });
        default = {};
        description = "Declared subcommands for completion and validation metadata.";
      };
    };
  };

  capabilityModule = submodule {
    options = {
      commands = mkOption {
        type = listOf str;
        default = [];
        description = "Commands that must be available at runtime.";
      };

      directories = mkOption {
        type = attrsOf str;
        default = {};
        description = "Named directories that must exist at runtime.";
      };

      files = mkOption {
        type = attrsOf str;
        default = {};
        description = "Named files that must exist at runtime.";
      };
    };
  };
in {
  options.hey = {
    enable = mkEnableOption "hey scripting environment";
    development.enable = mkEnableOption "optional Hey development workflow tools";
    diagnostics.enable = mkEnableOption "optional Hey diagnostic and build-output tools";
    extraPackages = mkOption {
      type = listOf package;
      default = [];
      description = "Additional tools to install alongside Hey.";
    };

    # Used by downstream consumers (e.g. info.json, hooks)
    info = mkOption {
      type = attrsOf attrs;
      default = {};
      description = "Public metadata for hey scripts to reference.";
    };

    # User-extensible hook mechanism
    hooks = mkOption {
      type = attrsOf (attrsOf lines);
      default = {};
      description = "Hook scripts organized by phase and name. Names without a NN- prefix receive 50-; resulting filenames must be unique within each phase.";
    };

    commands = mkOption {
      type = attrsOf commandModule;
      default = {};
      description = "Declarative command metadata consumed by hey runtime checks and completions.";
    };

    capabilities = mkOption {
      type = attrsOf (attrsOf capabilityModule);
      default = {};
      description = ''
        Runtime expectations grouped by subsystem. Nix modules declare
        capabilities here; hey consumes the generated manifest.
      '';
    };
  };

  config = {
    _module.args.heyBin = mkIf config.hey.enable "${heyPackage}/bin/hey";
    environment.systemPackages = mkIf config.hey.enable (
      [heyPackage janet pkgs.git pkgs.zsh pkgs.coreutils]
      ++ optionals config.hey.development.enable [
        pkgs.gcc
        pkgs.unstable.cached-nix-shell
        pkgs.nix-prefetch-git
        pkgs.just
        pkgs.process-compose
        pkgs.watchexec
      ]
      ++ optionals config.hey.diagnostics.enable [
        pkgs.jq
        pkgs.bind
        pkgs.dash
        pkgs.file
        pkgs.nix-output-monitor
        pkgs.wget
      ]
      ++ optionals (config.hey.diagnostics.enable && pkgs.stdenv.isLinux) [pkgs.lsof pkgs.procps]
      ++ config.hey.extraPackages
    );
    env = mkIf config.hey.enable {
      JANET_PATH = "${heyJanetDeps}/lib:${heyJanetLib}";
      JANET_TREE = "${heyJanetDeps}";
      HEY_PROCESS_SUPERVISOR = "${processSupervisor}/bin/nixi-process-supervisor";
    };
    environment.extraInit = mkIf config.hey.enable (mkAfter ''
      export PATH=${lib.escapeShellArg "${heyPackage}/bin"}:"$PATH"
    '');
    programs.zsh.shellInit = mkIf config.hey.enable (mkBefore ''
      # Source lookup for completions and nested Hey calls, not a PATH entry.
      export DOTFILES_BIN=${lib.escapeShellArg hey.binDir}
      export PATH=${lib.escapeShellArg "${heyPackage}/bin"}:"$PATH"
      rehash 2>/dev/null || true
    '');

    hey.commands = {
      build = {
        aliases = ["b"];
        description = "Build flake artifacts or recompile bin/hey.";
      };
      check = {
        description = "Run local validation suites.";
        subcommands = {
          unit.description = "Run Janet unit tests.";
          cli.description = "Run generic hey CLI checks.";
          "utm-cli".description = "Run UTM CLI checks.";
          flake.description = "Build flake checks.";
          framework.description = "Validate Nixi's internal output contract.";
          eval.description = "Evaluate system derivations.";
          build.description = "Build a host closure.";
          image.description = "Build a host image.";
          all.description = "Run the standard local validation suite.";
        };
      };
      clean = {
        description = "Remove known local runtime caches.";
        subcommands = {
          all.description = "Remove all supported local caches.";
          zsh.description = "Remove zsh and zgenom caches.";
          nix.description = "Remove hey Nix scratch state.";
          k9s.description = "Remove k9s cache state.";
          cache.description = "Remove hey cache state.";
        };
      };
      context = {
        aliases = ["ctx"];
        description = "Show the currently inferred hey/Nix context.";
      };
      dev = {
        description = "Run daily developer workflows.";
        subcommands = {
          doctor.description = "Run shell, editor, agent, and project checks.";
          status.description = "Print environment and project status.";
          shell.description = "Enter the project Nix development shell.";
          tools.description = "Check common developer tools.";
          check.description = "Run project fast validation.";
          test.description = "Run project tests.";
          ci.description = "Run project CI entrypoint.";
          up.description = "Start project services.";
          down.description = "Stop project services.";
          logs.description = "Show project service logs.";
          services.description = "Show project service status.";
          watch.description = "Watch project fast validation.";
          profile.description = "Run project profiling helper.";
          disk.description = "Show project and local cache disk hotspots.";
          git.description = "Show project git and worktree state.";
          clean.description = "Remove project build output.";
        };
      };
      direnv = {
        description = "Inspect or reload direnv state.";
        subcommands = {
          doctor.description = "Check direnv availability and current directory state.";
          reload.description = "Reload direnv.";
          status.description = "Print concise direnv status.";
        };
      };
      doctor = {
        description = "Diagnose local system health issues.";
        subcommands = {
          agents.description = "Check agent configuration and process state.";
          env.description = "Check local environment assumptions.";
          fix.description = "Run an explicit remediation.";
          nix.description = "Check Nix daemon and process state.";
          secrets.description = "Check inline secret markers without printing values.";
          shell.description = "Check shell runtime dependencies.";
          sync.description = "Check rebuild assumptions.";
          zed.description = "Check managed Zed settings and extensions.";
        };
      };
      eks = {
        description = "Manage AWS EKS access from declarative AWS host config.";
        subcommands = {
          list.description = "List configured clusters.";
          login.description = "Login to AWS SSO/SAML.";
          kubeconfig.description = "Refresh kubeconfig.";
          use.description = "Select kubectl context.";
          open.description = "Open k9s.";
          logs.description = "Stream logs.";
          "port-forward".description = "Forward a local port to a Kubernetes resource.";
          shell.description = "Open remote shell.";
          status.description = "Show cluster status.";
          credentials.description = "Show credential command.";
          env.description = "Print environment exports.";
          vpn.description = "Manage VPN.";
          doctor.description = "Check EKS tooling and cluster metadata.";
        };
      };
      gc.description = "Run garbage collection on the user's/system's profile.";
      hook.description = "Trigger scripts associated with an event.";
      host = {
        description = "Inspect and dispatch host-related commands.";
        subcommands = {
          doctor.description = "Check a declared host.";
          explain.description = "Explain a declared host build target.";
          list.description = "List flake hosts grouped by platform.";
        };
      };
      image = {
        description = "Build NixOS VM images.";
        subcommands = {
          list.description = "List image outputs for a host.";
          build.description = "Build a host image.";
        };
      };
      info.description = "Inspect flake metadata, IP addresses, or Git repository metadata.";
      path.description = "Display paths inside this flake and XDG areas.";
      profile = {
        aliases = ["pr"];
        description = "Manage or analyze a system or user nix profile.";
        subcommands = {
          current.description = "Print the active generation.";
          previous.description = "Print the previous generation.";
          rollback.description = "Activate a profile generation.";
          ls.description = "List profile generations.";
          rm.description = "Remove explicit profile generations.";
          prune.description = "Keep N entries including the active generation, without GC.";
          diff.description = "Compare generation store references.";
        };
      };
      project = {
        description = "Run project-local development workflows.";
        subcommands = {
          doctor.description = "Check project language, tools, direnv, and Codegraph readiness.";
          status.description = "Print project root, language, and git state.";
          shell.description = "Enter the project Nix development shell.";
          check.description = "Run project fast validation.";
          test.description = "Run project tests.";
          ci.description = "Run project CI entrypoint.";
          up.description = "Start project services.";
          down.description = "Stop project services.";
          logs.description = "Show project service logs.";
          services.description = "Show project service status.";
          watch.description = "Watch project fast validation.";
          profile.description = "Run project profiling helper.";
          disk.description = "Show project disk hotspots.";
          git.description = "Show project git and worktree state.";
          clean.description = "Remove project build output.";
        };
      };
      pull.description = "Update flake inputs.";
      reload = {
        aliases = ["re"];
        description = "Run reload hooks.";
      };
      repl.description = "Open a Janet, Nix, or nix-develop REPL.";
      search.description = "Search Nix packages from the command line.";
      security = {
        description = "Explicit advisory scans; no automatic update or deployment.";
        subcommands.scan.description = "Scan a selected Nix store path with an explicitly installed vulnix.";
      };
      ssh = {
        description = "Inspect local SSH process and tunnel state.";
        subcommands = {
          doctor.description = "Detect SSH tunnels, orphaned SSH processes, and zombie SSH processes.";
          ps.description = "List SSH processes and tunnel-like processes.";
        };
      };
      swap = {
        aliases = ["sw"];
        description = "List legacy swapped files for manual recovery (read-only).";
      };
      sync = {
        aliases = ["s"];
        description = "Rebuild this flake for the current host.";
        subcommands.plan.description = "Preview build tasks and cache downloads without building or activating.";
      };
      template = {
        description = "Initialize local project templates.";
        subcommands = {
          list.description = "List available templates.";
          init.description = "Copy a template into an empty directory.";
        };
      };
      tmux = {
        description = "Inspect tmux runtime state.";
        subcommands = {
          clean.description = "Remove dead tmux session state.";
          doctor.description = "Check tmux server, config, status, and bindings.";
          project.description = "Switch to or create a project session.";
          sessions.description = "List tmux sessions.";
          "swap-pane".description = "Move the active pane.";
        };
      };
      utm = {
        description = "Manage UTM-backed NixOS VMs.";
        subcommands = {
          ls.description = "List registered VMs.";
          status.description = "Show VM status.";
          start.description = "Start a VM.";
          stop.description = "Stop a VM.";
          "create-image".description = "Build and register a VM image.";
          update.description = "Deploy a host closure to a VM.";
          rollback.description = "Rollback the remote system profile.";
          generations.description = "List remote system generations.";
          "cleanup-generations".description = "Delete old remote generations.";
          diff.description = "Diff remote system closures.";
          ssh.description = "Open SSH or run a command.";
          current.description = "Show the remote current system.";
          check.description = "Run current and doctor checks.";
          doctor.description = "Check VM readiness and activation prerequisites.";
          ip.description = "Print VM IP address.";
          token.description = "Print k3s node token.";
        };
      };
      vars.description = "Get or set session or persistent state in userspace.";
      watch = {
        description = "Run common development feedback loops with watchexec.";
        subcommands = {
          eval.description = "Re-run host evaluation checks.";
          cli.description = "Re-run generic hey CLI checks.";
          flake.description = "Re-run flake and checked package checks.";
          tmux.description = "Re-run tmux doctor.";
          "utm-cli".description = "Re-run UTM CLI checks.";
          run.description = "Run a custom command under watchexec.";
        };
      };
    };

    hey.info = {
      identity = {
        host = config.networking.hostName;
        user = config.user.name;
      };
      theme.active = config.modules.theme.active;
      enabled = {
        shell = config.modules.shell.zsh.enable;
        zed = config.modules.editors.zed.enable;
        agents = (config.hey.capabilities.agents or {}) != {};
      };
    };

    home.dataFile = mkIf config.hey.enable (
      {
        # This file is intended as a reference for shell scripts to peek into to
        # do cheap feature-detection (using `hey vars ...`)
        "hey/info.json" = {
          text = toJSON config.hey.info;
        };
        "hey/commands.json" = {
          text = toJSON config.hey.commands;
        };
        "hey/capabilities.json" = {
          text = toJSON {
            version = 1;
            groups = config.hey.capabilities;
          };
        };
      }
      // (listToAttrs
        (flatten
          (mapAttrsToList
            (hook: hooks:
              mapAttrsToList
              (filename: names:
                if builtins.length names > 1
                then throw "hey.hooks.${hook}: names ${toJSON names} map to the same hook filename ${toJSON filename}"
                else
                  nameValuePair
                  "hey/hooks.d/${hook}.d/${filename}"
                  {
                    text = ''
                      #!/usr/bin/env zsh
                      set -e
                      setopt pipe_fail
                      ${hooks.${builtins.head names}}
                    '';
                    executable = true;
                  })
              (groupBy hookFilename (builtins.attrNames hooks)))
            config.hey.hooks)))
    );
  };
}
