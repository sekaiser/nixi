#!/usr/bin/env janet
# Run daily developer workflows.
#
# SYNOPSIS:
#   dev doctor
#   dev status
#   dev tools
#   dev shell
#   dev check
#   dev test
#   dev ci
#   dev up [PROCESS...]
#   dev down
#   dev logs [PROCESS]
#   dev services
#   dev watch
#   dev profile
#   dev disk
#   dev git
#   dev clean [--yes]
#
# SUBCOMMANDS:
#   doctor   Run shell, editor, agent, and project checks.
#   status   Print environment and project status.
#   tools    Check availability of common developer tools.
#   shell    Delegate to hey project shell.
#   check    Delegate to hey project check.
#   test     Delegate to hey project test.
#   ci       Delegate to hey project ci.
#   up       Delegate to hey project up.
#   down     Delegate to hey project down.
#   logs     Delegate to hey project logs.
#   services Delegate to hey project services.
#   watch    Delegate to hey project watch.
#   profile  Delegate to hey project profile.
#   disk     Delegate to hey project disk.
#   git      Delegate to hey project git.
#   clean    Delegate to hey project clean.

(use hey)
(use hey/cmd)

(def- usage
  "Usage: hey dev doctor|status|tools|shell|check|test|ci|up|down|logs|services|watch|profile|disk|git|clean [ARGS...] [--yes]")

(defn- command? [name]
  (truthy? (path/find name)))

(defn- print-tool [name]
  (if (command? name)
    (echof :check "%s command is available" name)
    (echof :warn "%s command is missing" name)))

(defn- run-hey [args]
  (let [cmd @[(path :bin "hey")]]
    (when (dryrun?)
      (array/push cmd "-!"))
    (array/concat cmd args)
    (if (dryrun?)
      (echof "DRYRUN: %s" (string/join cmd " "))
      (let [status (execute-clean cmd)]
        (unless (= 0 status)
          (exit status))))))

(defn- run-shell [label script]
  (if (dryrun?)
    (echof "DRYRUN: %s" script)
    (do
      (echof "%s" label)
      (let [status (execute-clean @["sh" "-c" script])]
        (unless (= 0 status)
          (exit status))))))

(defn- dev-tools []
  (each tool @["git"
               "direnv"
               "tmux"
               "zed"
               "rg"
               "fd"
               "fzf"
               "process-compose"
               "watchexec"
               "hyperfine"
               "samply"
               "cargo"
               "rust-analyzer"
               "cargo-nextest"
               "bacon"
               "cargo-deny"
               "cargo-mutants"
               "go"
               "gopls"
               "golangci-lint"
               "gotestsum"
               "java"
               "mvn"
               "gradle"
               "jdtls"
               "codegraph"
               "codex"
               "omp"]
    (print-tool tool)))

(defn- dev-doctor []
  (each subsystem [:shell :zed :agents]
    (when (flake/info :enabled subsystem)
      (run-hey @["doctor" (string subsystem)])))
  (run-hey @["project" "doctor"])
  (echof :check "developer doctor complete"))

(defn- dev-status []
  (run-hey @["context"])
  (run-hey @["project" "status"]))

(defn- dev-disk []
  (run-hey @["project" "disk"])
  (run-shell "local cache/store hotspots:"
             "du -sh ~/.cache ~/.local/share /nix/var/nix/profiles/per-user/$USER /nix/var/nix/gcroots 2>/dev/null | sort -h"))

(defcmd dev [_ subcmd & args &opts yes? --yes]
  (case subcmd
    "doctor" (if (empty? args) (dev-doctor) (abort usage))
    "status" (if (empty? args) (dev-status) (abort usage))
    "tools" (if (empty? args) (dev-tools) (abort usage))
    "shell" (if (empty? args) (run-hey @["project" "shell"]) (abort usage))
    "check" (if (empty? args) (run-hey @["project" "check"]) (abort usage))
    "test" (if (empty? args) (run-hey @["project" "test"]) (abort usage))
    "ci" (if (empty? args) (run-hey @["project" "ci"]) (abort usage))
    "up" (let [cmd @["project" "up"]]
           (array/concat cmd args)
           (run-hey cmd))
    "down" (if (empty? args) (run-hey @["project" "down"]) (abort usage))
    "logs" (if (< (length args) 2)
             (let [cmd @["project" "logs"]]
               (array/concat cmd args)
               (run-hey cmd))
             (abort usage))
    "services" (if (empty? args) (run-hey @["project" "services"]) (abort usage))
    "watch" (if (empty? args) (run-hey @["project" "watch"]) (abort usage))
    "profile" (if (empty? args) (run-hey @["project" "profile"]) (abort usage))
    "disk" (if (empty? args) (dev-disk) (abort usage))
    "git" (if (empty? args) (run-hey @["project" "git"]) (abort usage))
    "clean" (if (empty? args)
             (let [cmd @["project" "clean"]]
              (when yes?
                (array/push cmd "--yes"))
               (run-hey cmd))
             (abort usage))
    (abort usage)))
