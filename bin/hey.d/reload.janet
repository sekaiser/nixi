#!/usr/bin/env janet
# Reload running services.
#
# SYNOPSIS:
#   reload [all|tmux|zsh|direnv|k9s|cache]
#
# SUBCOMMANDS:
#   all   Reload all supported runtime config.
#   cache Remove hey cache state.
#   direnv Reload direnv for the current directory.
#   k9s   Remove k9s cache/screen state.
#   tmux  Reload tmux config from repo assets.
#   zsh   Clear zsh caches and print parent-shell restart guidance.
#
(use hey)
(use hey/cmd)
(import hey/sys)

(defn- tmux-active? []
  (not (empty? (or (os/getenv "TMUX") ""))))

(defn- run-reload-hooks []
  (unless (hey! hook reload -f -v)
    (abort "Reload hooks failed"))
  true)

(def- run-foreground execute!)

(defn- tmux-config-file []
  (path :config "tmux" "tmux.conf"))

(defn- tmux-theme-config-file []
  (ignore-errors (path :theme "config" "tmux.conf")))

(defn- reload-tmux [&opt force?]
  (cond
    (or force? (tmux-active?))
      (if (dryrun?)
        (do
          (echof "DRYRUN: tmux set-option -g -q @hey_reload 1")
          (echof "DRYRUN: tmux source-file %s" (tmux-config-file))
          (when-let [theme-config (tmux-theme-config-file)]
            (echof "DRYRUN: tmux source-file %s" theme-config))
          (echof "DRYRUN: tmux set-option -g -q -u @hey_reload")
          (echof "DRYRUN: tmux display-message %q" "Config reloaded from repo assets."))
        (do
          (echof :g "Reloading tmux...")
          (run-foreground @["tmux" "set-option" "-g" "-q" "@hey_reload" "1"])
          (var reloaded? false)
          (defer
            (let [status (ignore-errors
                           (execute-clean @["tmux" "set-option" "-g" "-q" "-u" "@hey_reload"]))]
              (unless (= 0 status)
                # Do not mask the source-file error if the server also exits.
                (if reloaded?
                  (exit (or status 1))
                  (echo :warn "Could not clear tmux reload flag; the server may have exited."))))
            (run-foreground @["tmux" "source-file" (tmux-config-file)])
            (when-let [theme-config (tmux-theme-config-file)]
              (run-foreground @["tmux" "source-file" theme-config]))
            (set reloaded? true))
          (run-foreground @["tmux" "display-message" "Config reloaded from repo assets."])
          (echo :check "tmux reloaded")))
    (echof :warn "tmux reload skipped; not inside tmux")))

(defn- reload-zsh []
  (when (run-reload-hooks)
    (echo :check "zsh caches cleared")
    (echof :warn "Restart current shell to reload zsh functions: exec zsh")))

(defn- reload-direnv []
  (if (dryrun?)
    (echof "DRYRUN: direnv reload")
    (if (path/find "direnv")
      (run-foreground @["direnv" "reload"])
      (echof :warn "direnv reload skipped; direnv is not on PATH"))))

(defn- reload-k9s []
  (execute! @[(path :bin "hey") "clean" "k9s"]))

(defn- reload-cache []
  (execute! @[(path :bin "hey") "clean" "cache"]))

(defn- reload-all []
  (echof :g "Reloading %s..." (or (os/getenv "XDG_CURRENT_DESKTOP") "system"))
  (when (run-reload-hooks)
    (echo :check "zsh caches cleared")
    (reload-tmux)
    (reload-direnv)
    (echof :warn "Restart current shell to reload zsh functions: exec zsh")
    (unless (dryrun?)
      (sys/notify "Finished reloading system" :icon 'checkmark :sound 'notify)))
  (echo :check "Done!"))

(defcmd reload [_ target & args]
  (unless (empty? args)
    (abort "Usage: hey reload [all|tmux|zsh|direnv|k9s|cache]"))
  (case* (or target "all")
    "all" (reload-all)
    "cache" (do
              (reload-cache)
              (echo :check "Done!"))
    "direnv" (do
               (reload-direnv)
               (echo :check "Done!"))
    "k9s" (do
            (reload-k9s)
            (echo :check "Done!"))
    "tmux" (do
             (reload-tmux true)
             (echo :check "Done!"))
    "zsh" (do
            (reload-zsh)
            (echo :check "Done!"))
    (abort "Usage: hey reload [all|tmux|zsh|direnv|k9s|cache]")))
