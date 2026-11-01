#!/usr/bin/env janet
# Apply the selected flake to a local or explicitly targeted host.
#
# SYNOPSIS:
#   sync [--fast] [--explain] [--flake FLAKE] [--host HOST] [COMMAND...]
#   sync plan [--flake FLAKE] [--host HOST]
#   sync rollback GENERATION
#   sync --rollback
#
# OPTIONS:
#   --explain     Print the inferred rebuild plan without executing it.
#   --flake FLAKE Rebuild another flake. FLAKE may include #HOST.
#   --host HOST   Rebuild another host from the selected flake.
#
# plan queries build/download requirements without activation, lock updates or
# evaluation-time builds. It may fetch public inputs and query binary caches.

(use hey)
(use hey/nix)
(use hey/cmd)
(import hey/process)
(import hey/system)

(defn- setenv-when [name value]
  (when value
    (os/setenv name value)))

(def- run process/capture)

(defn- run-foreground [args]
  (let [status (execute-clean args)]
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

(defn- rebuild-argv [target rebuild fast? action args]
  (let [argv @["sudo"
               "--preserve-env=DOTFILES,DOTFILES_HOME,NIX_CONFIG"
               rebuild
               "--show-trace"
               "--impure"
               "--flake"
               (flake-host-ref target)]]
    (when fast?
      (array/push argv "--fast"))
    (array/push argv action)
    (each arg args
      (array/push argv arg))
    argv))

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
        host (target :host)
        action (or cmd "switch")
        dotfiles (target :dotfiles)
        dotfiles-home (target :dotfiles)
        nix-config (or (os/getenv "NIX_CONFIG") "")
        build (build-target system target)
        rebuild (case system
                  "Darwin" "darwin-rebuild"
                  "Linux" "nixos-rebuild"
                  "<unsupported>")]
    (echof "host: %s" host)
    (echof "system: %s" system)
    (echof "flake: %s" (flake-host-ref target))
    (echof "DOTFILES: %s" dotfiles)
    (echof "DOTFILES_HOME: %s" dotfiles-home)
    (echof "NIX_CONFIG: %s" (if (empty? nix-config) "<unset>" "<set; contents hidden>"))
    (echof "NIX_PATH: <cleared for nix commands>")
    (echof "builder: %s" (if (nix/prefer-nom?) "nom" "nix"))
    (echof "build target: %s" (or build "<unsupported>"))
    (case* cmd
      "build" (echof "build command: %s build --impure --no-link %s"
                     (if (nix/prefer-nom?) "nom" "nix")
                     (or build "<unsupported>"))
      "rollback" (if (first args)
                   (each argv (system/rollback-commands system (path :profile) (first args))
                     (echof "rollback command: %s" (string/join argv " "))))
      (echof "rebuild command: sudo --preserve-env=DOTFILES,DOTFILES_HOME,NIX_CONFIG %s --show-trace --impure --flake %s#%s %s%s%s"
             rebuild
             (target :flake-ref)
             host
             (if fast? "--fast " "")
             action
             (if (empty? args) "" (string " " (string/join args " ")))))))

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

  (when explain?
    (explain-sync target cmd args fast?)
    (break))

  (unless (or (target :external?) (empty? (swapped-files)))
    (abort "There are swapped files among your dotfiles!"))

  (setenv-when "DOTFILES" (target :dotfiles))
  (setenv-when "DOTFILES_HOME" (target :dotfiles))
  (log "DOTFILES=%s DOTFILES_HOME=%s NIX_CONFIG=%s"
       (os/getenv "DOTFILES")
       (os/getenv "DOTFILES_HOME")
       (if (empty? (os/getenv "NIX_CONFIG")) "<unset>" "<set; contents hidden>"))

  (case* cmd
    "rollback"
    (if (not= (length args) 1)
      (abort "Usage: hey sync rollback GENERATION")
      (do (system/rollback (path :profile) (first args))
          (break)))
    ["check" "ch"]
    (let [argv @["nix" "flake" "check" "--impure"
                 "--no-warn-dirty"
                 "--no-use-registries"
                 "--no-write-lock-file"
                 "--no-update-lock-file"
                 (target :flake-ref)]]
      (if (dryrun?)
        (echof "DRYRUN: %s" (string/join argv " "))
        (run-foreground-without-nix-path argv)))
    "build"
    (let [system (local-system-name)
          build (build-target system target)]
      (unless build
        (abort "Unsupported system: %s" system))
      (if (dryrun?)
        (echof "DRYRUN: %s build --impure --no-link %s"
               (if (nix/prefer-nom?) "nom" "nix")
               build)
        (nix/build "--impure" "--no-link" build)))
    (match (local-system-name)
      "Darwin" (let [argv (rebuild-argv target "darwin-rebuild" fast? (or cmd "switch") args)]
                 (if (dryrun?)
                   (echof "DRYRUN: %s" (string/join argv " "))
                   (os/with-lock (path :runtime "profile-rm.lock")
                     (run-foreground-without-nix-path argv))))
      "Linux" (let [argv (rebuild-argv target "nixos-rebuild" fast? (or cmd "switch") args)]
                (if (dryrun?)
                  (echof "DRYRUN: %s" (string/join argv " "))
                  (os/with-lock (path :runtime "profile-rm.lock")
                    (run-foreground-without-nix-path argv))))))))
