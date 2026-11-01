#!/usr/bin/env janet
# Run common development feedback loops with watchexec.
#
# SYNOPSIS:
#   watch eval [HOST] [--flake FLAKE]
#   watch cli
#   watch flake [--flake FLAKE]
#   watch tmux
#   watch utm-cli
#   watch run COMMAND [ARGS...]
#
# SUBCOMMANDS:
#   eval     Re-run host evaluation checks when Nix/Janet files change.
#   cli      Re-run generic hey dry-run checks when Janet files change.
#   flake    Re-run flake checks when Nix or checked package sources change.
#   tmux     Re-run tmux doctor when tmux/Janet/Zsh files change.
#   utm-cli  Re-run UTM CLI dry-run checks when Janet files change.
#   run      Run a custom command under watchexec.

(use hey)
(use hey/cmd)
(import hey/process)

(defn- local-root [ref]
  (let [dir (if (string/has-prefix? "path:" ref) (slice ref 5) ref)]
    (when (or (empty? dir)
              (string/find "#" dir)
              (string/find "?" dir)
              (and (not (path/abspath? dir)) (string/find ":" dir)))
      (abort "Watching requires a local directory (optionally prefixed with path:), not a remote or revision-qualified flake: %s" ref))
    (path/abspath dir)))

(def- usage
  "Usage: hey watch eval [HOST] [--flake FLAKE] | hey watch cli | hey watch flake [--flake FLAKE] | hey watch tmux | hey watch utm-cli | hey watch run COMMAND [ARGS...]")

(defn- no-extra-args [args]
  (unless (empty? args)
    (abort usage)))

(defn- check-command [subcmd flake-opt args]
  (let [command (if flake-opt
                  @[(path :bin "hey") "check" "--flake" flake-opt subcmd]
                  @[(path :bin "hey") "check" subcmd])]
    (each arg args
      (array/push command arg))
    command))

(defcmd watch [_ subcmd & args
               &opts flake-opt ["--flake" flake-opt]]
  (when (and flake-opt (not (index-of subcmd ["eval" "flake"])))
    (abort "--flake is only supported by watch eval and watch flake"))
  (case* subcmd
    "eval" (do (when (> (length args) 1)
                 (abort usage))
               (let [root (local-root (or flake-opt (path :home)))]
                 (process/watch! root "nix,janet,lock"
                   (check-command "eval" (if flake-opt root) args))))
    "cli" (do (no-extra-args args)
              (process/watch! (path :framework) "janet" (check-command "cli" nil [])))
    "flake" (do (no-extra-args args)
                (let [root (local-root (or flake-opt (path :home)))]
                  (process/watch! root "nix,rs,toml,lock,py,janet,zsh,sh,json,md"
                    (check-command "flake" (if flake-opt root) []))))
    "tmux" (do (no-extra-args args)
               (process/watch! (path :framework) "nix,janet,zsh" @[(path :bin "hey") "tmux" "doctor"]))
    "utm-cli" (do (no-extra-args args)
                  (process/watch! (path :framework) "janet" (check-command "utm-cli" nil [])))
    "run" (if (empty? args)
           (abort "Usage: hey watch run COMMAND [ARGS...]")
           (process/watch! (os/cwd) nil args))
    (abort usage)))
