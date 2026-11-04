#!/usr/bin/env janet
# A helper for common Nix, nix-darwin, and VM operations.
#
# I envy the user story for Guix's CLI; Nix's does not spark joy, in my humble
# opinion. This script exists to abstract my more common Nix workflows, like
# rebuilding systems, cleaning up (nix-collect-garbage), managing the
# system profile (rollback or diffing), updating flakes, and dotfile management
# (and then some).
#
# SYNOPSIS:
#   hey [-?|-??|-???|-!] [-h|--help] COMMAND [ARGS...]
#
# OPTIONS:
#   -!           -- Do a dry run.
#   -?,-??,-???  -- Enable debug (verbose) mode.
#   -h,--help    -- Display the documentation embedded in a target script's
#                   header.
#
# COMMANDS:
#   - build|b    -- Build flake artifacts or recompile bin/hey
#   - check      -- Run local validation suites
#   - clean      -- Remove known local runtime caches
#   - context|ctx -- Show the currently inferred hey/Nix context
#   - dev        -- Run daily developer workflows
#   - doctor     -- Diagnose local system health issues
#   - direnv     -- Inspect or reload direnv state
#   - exec       -- Dispatch through host, desktop asset, or shared bin shims
#   - get|set    -- Alias for hey vars {get,set} ...
#   - gc         -- Run garbage collection on the user's/system's profile
#   - help|h     -- Display documentation for the command
#   - hook       -- Trigger scripts associated with an event
#   - host       -- Dispatch to the selected host inventory's $HOST/bin
#   - eks        -- Manage AWS EKS access from declarative AWS host config
#   - image      -- Build NixOS VM images
#   - info       -- Display information about current system (JSON)
#   - path       -- Display paths inside this flake and XDG areas
#   - profile    -- Manage or analyze a system or user nix profile
#   - project    -- Run project-local development workflows
#   - pull       -- Update flake inputs
#   - reload     -- Run reload hooks
#   - repl       -- Open a Janet, Nix, or nix-develop REPL
#   - search     -- Search Nix packages from the command line
#   - security   -- Explicit advisory scans of selected Nix store paths
#   - ssh        -- Inspect local SSH process and tunnel state
#   - swap       -- List legacy swapped files for manual recovery (read-only)
#   - sync|s     -- Rebuild this flake for the current host
#   - template   -- Initialize local project templates
#   - tmux       -- Inspect tmux runtime state
#   - utm        -- Manage UTM-backed NixOS VMs
#   - watch      -- Run common development feedback loops with watchexec
#   - which      -- Print out the script's path (with arguments) w/o executing it
#   - wm         -- Dispatch to framework assets/$WM/bin
#   - vars       -- Get or set session or persistent state in userspace.
#   - @*         -- Dispatch to framework assets/${1#@}/bin
#   - .*         -- Tries to be smart. Looks for any executable under host, wm,
#                   then framework bin.

(use hey)
(use hey/cmd)

(def- command-directory
  (path/join (path/dirname (path/abspath (dyn :current-file))) "hey.d"))

(defn- lazy-cmd [name]
  (register-lazy name (path/join command-directory (string name ".janet")))
  (fn [_ & args]
    [:eval (cmd name) ;args]))

(defn main [_ & args]
  (dispatch [[:build :b]    (lazy-cmd 'build)
             :check         (lazy-cmd 'check)
             :clean         (lazy-cmd 'clean)
             [:context :ctx] (lazy-cmd 'context)
             :dev           (lazy-cmd 'dev)
             :doctor        (lazy-cmd 'doctor)
             :direnv        (lazy-cmd 'direnv)
             :eks           (lazy-cmd 'eks)
             [:get :set]    |[:eval (cmd 'vars) ;$&]
             :gc            (lazy-cmd 'gc)
             :hook          (lazy-cmd 'hook)
             :host          (lazy-cmd 'host)
             :image         (lazy-cmd 'image)
             :info          (lazy-cmd 'info)
             :path          (lazy-cmd 'path)
             [:profile :pr] (lazy-cmd 'profile)
             :project       (lazy-cmd 'project)
             :pull          (lazy-cmd 'pull)
             [:reload :re]  (lazy-cmd 'reload)
             :repl          (lazy-cmd 'repl)
             :search        (lazy-cmd 'search)
             :security      (lazy-cmd 'security)
             :ssh           (lazy-cmd 'ssh)
             [:swap :sw]    (lazy-cmd 'swap)
             [:sync :s]     (lazy-cmd 'sync)
             :template      (lazy-cmd 'template)
             :theme         |[:exec (path (keyword $0) "bin") ;$&]
             :tmux          (lazy-cmd 'tmux)
             :utm           (lazy-cmd 'utm)
             :vars          (lazy-cmd 'vars)
             :watch         (lazy-cmd 'watch)
             :wm            |[:exec (path (keyword $0) "bin") ;$&]
             :exec          |[:exec (or (path/find $1)
                                        (abort "%s: command not found" $1))
                                    ;$&]
             '(+ "./" "/")  |[:exec ;$&]
             '(* ".")       |[:exec ;(or (resolve [(path :host "bin")
                                               ;(if-let [wm-bin (ignore-errors (path :wm "bin"))]
                                                  [wm-bin]
                                                  [])
                                               (path :bin)]
                                              (slice $0 1) ;$&)
                                         (abort "%s: command not found" $0))]
             '(* "@")       |[:exec (path :config (slice $0 1) :bin) ;$&]]
            ;args))
