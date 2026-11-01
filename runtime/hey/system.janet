(use hey)
(import ./process)

(defn platform []
  (process/output @["uname"]))

(defn rollback-commands [system profile generation]
  (unless (peg/match '(* :d+ -1) (string generation))
    (error "Generation must be a non-negative integer"))
  (case system
    "Darwin" @[@["sudo" "darwin-rebuild" "--switch-generation" (string generation)]]
    "Linux" @[@["sudo" "nix-env" "--switch-generation" (string generation) "--profile" profile]
              @["sudo" (string profile "/bin/switch-to-configuration") "switch"]]
    (errorf "Unsupported system: %s" system)))

(defn verify-current [profile]
  (if (dryrun?)
    (echof "DRYRUN: verify /run/current-system matches %s" profile)
    (let [expected (if (path/file? (path/join profile "systemConfig"))
                    (string/trim (slurp (path/join profile "systemConfig")))
                    (os/realpath profile))
          actual (os/realpath "/run/current-system")]
      (unless (= (os/realpath expected) actual)
        (abort "Activation did not converge: running %s, selected %s" actual expected)))))

(defn rollback-under-lock [profile generation]
  (each command (rollback-commands (platform) profile generation)
    (process/run! command))
  (verify-current profile))

(defn rollback [profile generation]
  (os/with-lock (path :runtime "profile-rm.lock")
    (rollback-under-lock profile generation)))

(defn boot-refresh-commands [system profile]
  (case system
    "Linux" @[@["sudo" (string profile "/bin/switch-to-configuration") "boot"]]
    "Darwin" @[]
    (errorf "Unsupported system: %s" system)))

(defn delete-generations [profile generations user?]
  # Callers hold the profile-removal lock and validate the complete plan first.
  # Resolve platform support before deletion; a failed refresh must propagate
  # before any following garbage collection. Empty plans still reconcile boot
  # entries, so retrying a partially successful Linux prune repairs its menu.
  (let [refresh (if user? [] (boot-refresh-commands (platform) profile))]
    (unless (empty? generations)
      (process/run! @[;(if user? [] ["sudo"]) "nix-env"
                      "--delete-generations" "--profile" profile ;generations]))
    (each command refresh (process/run! command))))
