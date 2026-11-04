#!/usr/bin/env janet
# Build the selected host configuration as the caller, then activate locally.
#
# SYNOPSIS:
#   sync [--fast] [--explain] [--flake FLAKE] [--host HOST] [COMMAND...]
#   sync plan [--flake FLAKE] [--host HOST]
#   sync rollback GENERATION
#   sync --rollback
#
# OPTIONS:
#   --fast        Compatibility flag; direct builds do not re-execute rebuild tools.
#   --explain     Print the inferred rebuild plan without executing it.
#   --flake FLAKE Rebuild another flake. FLAKE may include #HOST.
#   --host HOST   Select another configuration from the flake for this machine.
#
# plan queries build/download requirements without activation, lock updates or
# evaluation-time builds. It may fetch public inputs and query binary caches.
# Local activation supports switch on both systems, activate on Darwin, and
# boot/test/dry-activate on Linux. Remote deployment and custom profiles require
# a separately reviewed native procedure. Build options never reach sudo.

(use hey)
(use hey/nix)
(use hey/cmd)
(import hey/process)
(import hey/system)
(import spork/json)

(defn- setenv-when [name value]
  (when value
    (os/setenv name value)))

(def- run process/capture)

(defn- run-foreground [args &opt environment]
  (let [status (execute-clean args nil environment)]
    (unless (= 0 status)
      (exit status))))

(defn- without-nix-path [thunk]
  (let [old (os/getenv "NIX_PATH")]
    (os/setenv "NIX_PATH" nil)
    (defer (os/setenv "NIX_PATH" old)
      (thunk))))

(defn- run-foreground-without-nix-path [args]
  (without-nix-path
    (fn []
      (run-foreground args))))

(defn- command-output [args]
  (let [result (run args)]
    (unless (= 0 (result :status))
      (abort "%s failed: %s"
             (string/join args " ")
             (if (empty? (result :err)) (result :out) (result :err))))
    (string/trim (result :out))))

(defn- local-system-name []
  (command-output @["uname"]))

(defn- sync-target [flake-opt host-opt]
  (let [[ref ref-host] (nix/split-flake-ref (or flake-opt (path :home)) (path :home))
        host (or host-opt ref-host (flake :host))]
    (unless host
      (abort "Could not infer host; pass --host HOST or --flake FLAKE#HOST"))
    {:flake-ref ref
     :host host
     :dotfiles (if flake-opt ref (flake :path))
     :external? (not (nil? flake-opt))}))

(defn- flake-host-ref [target]
  (string (target :flake-ref) "#" (target :host)))

(defn- build-options [args]
  (def result @[])
  (var index 0)
  (while (< index (length args))
    (let [flag (args index)
          count (case* flag
                  ["--max-jobs" "-j" "--cores"] 1
                  "--option" 2
                  ["--offline" "--keep-going" "-k" "--keep-failed" "-K"
                   "--print-build-logs" "-L" "--show-trace" "--fallback"] 0
                  (abort "Unsupported sync argument: %s. Use a reviewed native procedure for remote targets, custom profiles or activation flags." flag))]
      (when (>= (+ index count) (length args))
        (abort "Missing value for sync argument: %s" flag))
      (for offset 0 (+ count 1)
        (array/push result (args (+ index offset))))
      (+= index (+ count 1))))
  result)

(defn- store-output? [value]
  (and (string? value)
       (string/has-prefix? "/nix/store/" value)
       (let [name (slice value 11)]
         (and (> (length name) 33)
              (= (get name 32) 45)
              (peg/match '(* (some (set "0123456789abcdfghijklmnpqrsvwxyz")) -1) (slice name 0 32))
              (peg/match '(* (some (set "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+._?=-")) -1) (slice name 33))
              (not (string/has-suffix? ".drv" name))))))

(defn- checked-output [text]
  (let [decoded (try (json/decode text :keywords true) ([err fib] nil))
        output (try
                 (when (and (index-of (type decoded) [:array :tuple]) (= 1 (length decoded)))
                   (get-in decoded [0 :outputs :out]))
                 ([err fib] nil))]
    (unless (store-output? output)
      (abort "Build did not report exactly one canonical local system output (contents hidden)"))
    output))

(defn- build-arguments [target flags & args]
  @["--impure" "--no-write-lock-file" "--no-update-lock-file"
    "--option" "accept-flake-config" "false" ;args ;flags target])

(defn- rooted-build [target link flags]
  (let [argv @["nix" "build" ;(build-arguments target flags "--json" "--out-link" link)]
        result (without-nix-path (fn [] (process/capture argv nil (* 64 1024) true)))]
    (unless (= 0 (result :status)) (exit (result :status)))
    (checked-output (result :out))))

(defn- require-normal-user []
  (let [uid (command-output @["id" "-u"])]
    (unless (peg/match '(* :d+ -1) uid) (abort "Could not determine the calling user"))
    (when (= uid "0")
      (abort "Run hey sync as the normal user; only the fixed-output activation step uses sudo"))))

(defn- activation-helper [directory]
  (let [helper (or (os/getenv "HEY_SYSTEM_ACTIVATOR")
                  (string (rooted-build (nix/flake-target (string "path:" (path :framework)) "system-activation")
                                        (path/join directory "activator") [])
                          "/bin/nixi-system-activate"))
        suffix "/bin/nixi-system-activate"]
    (unless (and (string/has-suffix? suffix helper)
                 (store-output? (string/no-suffix suffix helper)))
      (abort "System activator must come from the immutable Nixi package"))
    helper))

(defn- swapped-files []
  (let [result (run @[(path :bin "hey") "swap" "--list"])]
    (unless (= 0 (result :status))
      (abort "Could not list swapped files:\n%s"
             (if (empty? (result :err)) (result :out) (result :err))))
    (result :out)))

(defn- build-target [system target]
  (case system
    "Darwin" (nix/darwin-system-target (target :flake-ref) (target :host))
    "Linux" (nix/nixos-toplevel-target (target :flake-ref) (target :host))))

(defn- action-target [system target action]
  (if (index-of action ["build-vm" "build-vm-with-bootloader"])
    (nix/flake-target (target :flake-ref) "nixosConfigurations" (target :host)
      "config" "system" "build" (if (= action "build-vm") "vm" "vmWithBootLoader"))
    (build-target system target)))

(defn- activate-local [target system action flags]
  (os/with-lock (path :runtime "profile-rm.lock")
    (let [selected (command-output @["readlink" "-f" (path :profile)])
          running (command-output @["readlink" "-f" "/run/current-system"])]
      (unless (and (store-output? selected) (store-output? running))
        (abort "Could not snapshot an existing local system; use a reviewed native bootstrap procedure"))
      (let [directory (process/temporary-directory "hey-sync")]
        (defer (unless (= 0 (execute-clean @["rm" "-rf" "--" directory]))
                 (echo :warn "Could not remove this sync's temporary build roots"))
          (let [candidate (rooted-build (build-target system target) (path/join directory "candidate") flags)
                helper (activation-helper directory)
                sudo (or (path/find "sudo") (abort "sudo is required for local activation"))
                # Clear the environment before even starting sudo or its shell
                # launcher. Private input credentials remain in the user build.
                argv @[(os/realpath sudo) "--" helper "--action" action
                       "--candidate" candidate "--expected-profile" selected "--expected-running" running]]
            (run-foreground argv @{"PATH" "/usr/bin:/bin:/usr/sbin:/sbin"})))))))

(defn- plan-sync [target args fast? explain?]
  (unless (and (empty? args) (not fast?))
    (abort "Usage: hey sync plan [--flake FLAKE] [--host HOST]"))
  (let [system (local-system-name)
        build (build-target system target)]
    (unless build
      (abort "Unsupported system: %s" system))
    (let [argv @["nix" "build" "--dry-run" "--no-link" "--impure"
                 "--no-write-lock-file" "--no-update-lock-file"
                 "--option" "allow-import-from-derivation" "false"
                 "--option" "accept-flake-config" "false"
                 build]]
      (if (or (dryrun?) explain?)
        (echof "DRYRUN: %s" (string/join argv " "))
        (do
          (echo "Preview only: Nix reports build tasks, downloads and sizes below. No activation or lock update.")
          (echo "Evaluation-time builds are disabled. Results depend on current caches/store; this is not a time estimate.")
          (run-foreground-without-nix-path argv))))))

(defn- explain-sync [target cmd args fast?]
  (let [system (local-system-name)
        action (or cmd "switch")
        build (action-target system target action)]
    (when (dryrun?) (echo "DRYRUN: build and activation plan"))
    (echof "host: %s" (target :host))
    (echof "system: %s" system)
    (echof "flake: %s" (flake-host-ref target))
    (echof "DOTFILES: %s" (target :dotfiles))
    (echof "DOTFILES_HOME: %s" (target :dotfiles))
    (echof "NIX_CONFIG: %s" (if (empty? (or (os/getenv "NIX_CONFIG") "")) "<unset>" "<set; contents hidden>"))
    (echo "NIX_PATH: <cleared for nix commands>")
    (echof "build target: %s" (or build "<unsupported>"))
    (case* cmd
      "rollback" (when (first args)
                   (each argv (system/rollback-commands system (path :profile) (first args))
                     (echof "rollback command: %s" (string/join argv " "))))
      "--rollback" (echo "rollback command: hey profile rollback")
      "build" (echof "build command: %s build %s"
                     (if (nix/prefer-nom?) "nom" "nix")
                     (string/join (build-arguments build (build-options args) "--no-link") " "))
      ["build-vm" "build-vm-with-bootloader"]
      (echof "build command: %s build %s" (if (nix/prefer-nom?) "nom" "nix")
             (string/join (build-arguments build (build-options args) "--out-link" "result-vm") " "))
      ["check" "ch"] (echof "check command: %s"
                           (string/join @["nix" "flake" "check" "--impure" "--no-warn-dirty" "--no-use-registries"
                                          "--no-write-lock-file" "--no-update-lock-file"
                                          ;(build-options args) (target :flake-ref)] " "))
      (do
        (echof "build command: nix build %s"
               (string/join (build-arguments build (build-options args) "--json" "--out-link" "<temporary-gc-root>") " "))
        (echof "activation command: env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin sudo -- <immutable-activator> --action %s --candidate <built-output> --expected-profile <checkpoint> --expected-running <checkpoint>" action)
        (echo "Activation receives fixed store paths, no flake reference or caller NIX_CONFIG.")))
    (when fast? (echo "--fast: compatibility flag; direct builds do not re-execute a rebuild frontend."))))

(defcmd sync [_ cmd & args
              &opts fast? --fast
              explain? --explain
              flake-opt ["--flake" flake-opt]
              host-opt ["--host" host-opt]]
  (let [target (sync-target flake-opt host-opt)]
    (when (= (target :host) "nixos")
      (abort "HOST is 'nixos'. Did you forget to change it?"))
    (when (= cmd "plan")
      (plan-sync target args fast? explain?)
      (break))
    (when (= cmd "--rollback")
      (unless (empty? args) (abort "Usage: hey sync --rollback"))
      (if explain? (explain-sync target cmd args fast?)
        (execute! @[(path :bin "hey") "profile" "rollback"]))
      (break))
    (when (= cmd "rollback")
      (unless (= 1 (length args)) (abort "Usage: hey sync rollback GENERATION"))
      (if explain? (explain-sync target cmd args fast?)
        (system/rollback (path :profile) (first args)))
      (break))
    (let [system (local-system-name)
          action (or cmd "switch")
          build (build-target system target)
          build-only? (index-of action ["build" "build-vm" "build-vm-with-bootloader"])
          check? (index-of action ["check" "ch"])
          flags (build-options args)]
      (unless build (abort "Unsupported system: %s" system))
      (unless (or build-only? check?
                  (index-of action (if (= system "Darwin") ["switch" "activate"] ["switch" "boot" "test" "dry-activate"])))
        (abort "Unsupported local sync action: %s" action))
      (when (or explain? (dryrun?))
        (explain-sync target cmd args fast?)
        (break))
      (require-normal-user)
      (unless (or (target :external?) (empty? (swapped-files)))
        (abort "There are swapped files among your dotfiles!"))
      (setenv-when "DOTFILES" (target :dotfiles))
      (setenv-when "DOTFILES_HOME" (target :dotfiles))
      (log "DOTFILES=%s DOTFILES_HOME=%s NIX_CONFIG=%s"
           (os/getenv "DOTFILES") (os/getenv "DOTFILES_HOME")
           (if (empty? (or (os/getenv "NIX_CONFIG") "")) "<unset>" "<set; contents hidden>"))
      (cond
        check? (run-foreground-without-nix-path
                 @["nix" "flake" "check" "--impure" "--no-warn-dirty" "--no-use-registries"
                   "--no-write-lock-file" "--no-update-lock-file" ;flags (target :flake-ref)])
        build-only? (nix/build ;(build-arguments
                                 (action-target system target action)
                                 flags ;(if (= action "build") ["--no-link"] ["--out-link" "result-vm"])))
        (activate-local target system action flags)))))
