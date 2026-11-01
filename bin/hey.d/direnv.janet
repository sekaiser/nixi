#!/usr/bin/env janet
# Inspect or reload direnv state.
#
# SYNOPSIS:
#   direnv doctor
#   direnv reload
#   direnv status
#
# SUBCOMMANDS:
#   doctor  Check direnv availability, config, and current directory state.
#   reload  Run direnv reload in the current directory.
#   status  Print concise direnv status for the current directory.

(use hey)
(use hey/cmd)
(import hey/process)

(def- usage "Usage: hey direnv doctor|reload|status")

(defn- success [label]
  (echof :check "%s" label)
  true)

(defn- failure [label &opt detail]
  (echof :error "%s" label)
  (when (and detail (not (empty? detail)))
    (echo :err detail))
  false)

(defn- warning [label &opt detail]
  (echof :warn "%s" label)
  (when (and detail (not (empty? detail)))
    (echo :err detail))
  false)

(defn- direnv-file []
  (var dir (os/cwd))
  (var found nil)
  (while (not found)
    (let [candidate (path/join dir ".envrc")]
      (cond (path/file? candidate) (set found candidate)
            (= dir "/") (break)
            (set dir (path/join dir "..")))))
  found)

(defn- print-state []
  (let [file (direnv-file)]
    (echof "directory: %s" (os/cwd))
    (echof "envrc: %s" (or file "<none>"))
    (echof "DIRENV_FILE: %s" (or (os/getenv "DIRENV_FILE") "<unset>"))
    (echof "DIRENV_DIR: %s" (or (os/getenv "DIRENV_DIR") "<unset>"))))

(defn- direnv-status []
  (unless (dryrun?) (print-state))
  (process/run! @["direnv" "status"]))

(defn- direnv-reload []
  (process/run! @["direnv" "reload"]))

(defn- direnv-doctor []
  (var ok true)
  (if (path/find "direnv")
    (success "direnv command is available")
    (do
      (set ok false)
      (failure "direnv command is available")))
  (let [config (path/xdg :config "direnv/direnv.toml")
        envrc (direnv-file)]
    (if (path/file? config)
      (success "direnv config exists")
      (warning "direnv config is not generated yet" config))
    (if envrc
      (do
        (success ".envrc found")
        (echof "envrc: %s" envrc))
      (warning ".envrc not found for current directory"))
    (when ok
      (let [allow-result (process/probe @["direnv" "status"])]
        (if (= 0 (allow-result :status))
          (success "direnv status is readable")
          (do
            (set ok false)
            (failure "direnv status is not readable"
                     (if (empty? (allow-result :err)) (allow-result :out) (allow-result :err))))))))
  (if ok
    (echo :check "direnv doctor passed")
    (exit 1)))

(defcmd direnv [_ subcmd & args]
  (unless (empty? args)
    (abort usage))
  (case* subcmd
    "doctor" (if (dryrun?) (echo "DRYRUN: direnv doctor") (direnv-doctor))
    "reload" (direnv-reload)
    "status" (direnv-status)
    (abort usage)))
