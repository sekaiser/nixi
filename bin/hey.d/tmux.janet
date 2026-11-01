#!/usr/bin/env janet
# Inspect the running tmux server.
#
# SYNOPSIS:
#   tmux clean
#   tmux doctor
#   tmux project [NAME] [PATH]
#   tmux sessions
#   tmux swap-pane left|right|up|down|master
#
# SUBCOMMANDS:
#   clean  Remove dead tmux sessions and report remaining sessions.
#   doctor  Check server reachability, config, prefix, and important bindings.
#   project  Switch to or create a project session rooted at PATH.
#   sessions  List tmux sessions.
#   swap-pane  Swap current pane with a neighboring pane.

(use hey)
(use hey/cmd)

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

(import hey/process)
(def- run process/probe)

(defn- command-output [label args]
  (let [result (run args)]
    (if (= 0 (result :status))
      (do
        (success label)
        (result :out))
      (do
        (failure label (if (empty? (result :err)) (result :out) (result :err)))
        # Do not repeat expensive probes against a stalled or flooding server.
        (when (index-of (result :status) [124 125]) (exit 1))
        nil))))

(defn- print-field [name value]
  (echof "%s: %s" name (if (or (nil? value) (empty? value)) "-" value)))

(defn- xdg-config-file [& parts]
  (path/join
    (or (os/getenv "XDG_CONFIG_HOME")
        (path/join (os/getenv "HOME") ".config"))
    ;parts))

(defn- file-content [file]
  (when (= :file (os/stat file :mode))
    (string (slurp file))))

(defn- generated-file-check [label repo-file generated-file]
  (let [repo-content (file-content repo-file)
        generated-content (file-content generated-file)]
    (cond
      (nil? repo-content)
        (warning (string label " repo source is missing") repo-file)
      (nil? generated-content)
        (warning (string label " generated file is missing") generated-file)
      (= repo-content generated-content)
        (success (string label " generated file matches repo"))
      (warning (string label " generated file differs from repo")
        (string/format "repo: %s\ngenerated: %s\nRun darwin-rebuild/home-manager activation to persist current repo assets."
                       repo-file generated-file)))))

(defn- tmux-swap-pane-helper []
  (path :config "tmux" "bin" "swap-pane.zsh"))

(def- run-foreground execute!)

(defn- tmux-swap-pane [direction]
  (unless (index-of direction ["left" "right" "up" "down" "master"])
    (abort "Usage: hey tmux swap-pane left|right|up|down|master"))
  (if (dryrun?)
    (echof "DRYRUN: %s %s" (tmux-swap-pane-helper) direction)
    (run-foreground @[(tmux-swap-pane-helper) direction])))

(defn- tmux-sessions []
  (if (dryrun?)
    (echof "DRYRUN: tmux list-sessions -F '#S\t#{session_windows}\t#{session_attached}\t#{session_created_string}'")
    (run-foreground @["tmux" "list-sessions" "-F" "#S\t#{session_windows}\t#{session_attached}\t#{session_created_string}"])))

(defn- session-name-from-path [dir]
  (string/replace "." "_" (string/replace ":" "_" (path/basename dir))))

(defn- tmux-project [name dir]
  (let [project-dir (path/abspath (or dir (os/cwd)))
        session (or name (session-name-from-path project-dir))
        target (string "=" session)]
    (if (dryrun?)
      (do
        (echof "DRYRUN: tmux has-session -t %s" target)
        (echof "DRYRUN: tmux new-session -d -s %s -c %s" session project-dir)
        (echof "DRYRUN: tmux switch-client -t %s || tmux attach-session -t %s" target target))
      (do
        (let [result (run @["tmux" "has-session" "-t" target])]
          (unless (index-of (result :status) [0 1])
            (failure "tmux session state is not readable" (result :err))
            (exit 1))
          (unless (= 0 (result :status))
            (run-foreground @["tmux" "new-session" "-d" "-s" session "-c" project-dir]))
          (let [switch-status (os/execute @["tmux" "switch-client" "-t" target] :p)]
            (unless (= 0 switch-status)
              (run-foreground @["tmux" "attach-session" "-t" target]))))))))

(defn- tmux-clean []
  (if (dryrun?)
    (do
      (echof "DRYRUN: tmux list-sessions")
      (echof "DRYRUN: tmux kill-session for detached zero-window sessions if tmux reports any"))
    (do
      (let [result (run @["tmux" "list-sessions" "-F" "#S\t#{session_windows}\t#{session_attached}"])]
        (if (= 0 (result :status))
          (do
            (each line (string/split "\n" (result :out))
              (let [fields (string/split "\t" line)
                    session (get fields 0)
                    windows (get fields 1)
                    attached (get fields 2)]
                (when (and session (= windows "0") (= attached "0"))
                  (run-foreground @["tmux" "kill-session" "-t" session]))))
            (tmux-sessions))
          (if (= 1 (result :status))
            (warning "tmux server has no sessions" (result :err))
            (do
              (failure "tmux session state is not readable" (result :err))
              (exit 1))))))))

(defn- tmux-doctor []
  (when (dryrun?)
    (echo "DRYRUN: inspect tmux server, effective options, key tables and installed assets")
    (break))

  (unless (path/find "tmux")
    (failure "tmux binary is available")
    (exit 1))
  (success "tmux binary is available")
  (print-field "tmux" (path/find "tmux"))

  (var ok true)
  (defn inspect [label args]
    (let [output (command-output (string label " is readable") args)]
      (if output
        (print-field label output)
        (set ok false))
      output))

  (inspect "client-version" @["tmux" "-V"])
  (when (inspect "server" @["tmux" "display-message" "-p"
                           "version=#{version} socket=#{socket_path} pid=#{pid}"])
    (inspect "config-files" @["tmux" "display-message" "-p" "#{config_files}"])
    # Report effective settings, not a second copy of one theme's preferences.
    # Custom prefixes, widths, status bars and bindings are valid configuration.
    (each option ["prefix" "status" "status-keys" "status-left" "status-right"
                  "status-left-length" "status-right-length"]
      (inspect option @["tmux" "show-options" "-gqv" option]))
    (inspect "escape-time" @["tmux" "show-options" "-sqv" "escape-time"])
    (inspect "mode-keys" @["tmux" "show-window-options" "-gv" "mode-keys"])
    (each table ["prefix" "root"]
      (unless (command-output (string table " key table is readable")
                @["tmux" "list-keys" "-T" table])
        (set ok false)))

    # Drift is advisory: consumers may intentionally customize generated files.
    (each file ["tmux.conf" "bin/swap-pane.zsh" "bin/status-right.zsh" "bin/status-action.zsh"]
      (generated-file-check file
        (path :config "tmux" file)
        (path/join (or (os/getenv "TMUX_HOME") (xdg-config-file "tmux")) file))))

  (if ok
    (echo :check "tmux doctor passed")
    (exit 1)))

(defcmd tmux [_ subcmd direction & args]
  (case* subcmd
    "clean" (if (or direction (not (empty? args)))
              (abort "Usage: hey tmux clean | hey tmux doctor | hey tmux project [NAME] [PATH] | hey tmux sessions | hey tmux swap-pane left|right|up|down|master")
              (tmux-clean))
    "doctor" (if (or direction (not (empty? args)))
               (abort "Usage: hey tmux clean | hey tmux doctor | hey tmux project [NAME] [PATH] | hey tmux sessions | hey tmux swap-pane left|right|up|down|master")
               (tmux-doctor))
    "project" (if (> (length args) 1)
                (abort "Usage: hey tmux project [NAME] [PATH]")
                (tmux-project direction (first args)))
    "sessions" (if (or direction (not (empty? args)))
                 (abort "Usage: hey tmux sessions")
                 (tmux-sessions))
    "swap-pane" (if (or (not direction) (not (empty? args)))
                  (abort "Usage: hey tmux swap-pane left|right|up|down|master")
                  (tmux-swap-pane direction))
    (abort "Usage: hey tmux clean | hey tmux doctor | hey tmux project [NAME] [PATH] | hey tmux sessions | hey tmux swap-pane left|right|up|down|master")))
