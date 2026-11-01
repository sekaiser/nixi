(import ./process)

(defn ssh/connection [user host]
  (string/trim (string/format "%s@%s" user host)))

(defn ssh/trusted-options []
  @["-o" "BatchMode=yes" "-o" "ConnectTimeout=5"
    "-o" "StrictHostKeyChecking=yes" "-o" "UpdateHostKeys=no"
    "-o" "LogLevel=ERROR"])

(defn ssh/interactive-options []
  @["-o" "StrictHostKeyChecking=ask" "-o" "UpdateHostKeys=no"])

(defn ssh/shell-quote [value]
  (string "'" (string/replace "'" "'\"'\"'" value) "'"))

(defn ssh/remote-command [remote-args]
  # OpenSSH joins its trailing argv into a string for the remote shell.
  # Encode structured arguments exactly once at this boundary.
  (string/join (map ssh/shell-quote remote-args) " "))

(defn ssh/args [ssh-opts conn remote-cmd]
  (let [args @["ssh"]]
    (each opt ssh-opts
      (array/push args opt))
    (array/push args conn)
    (array/push args remote-cmd)
    args))

(defn ssh/command-args [ssh-opts conn remote-args]
  (if (empty? remote-args)
    @["ssh" ;ssh-opts conn]
    (ssh/args ssh-opts conn (ssh/remote-command remote-args))))

(defn ssh/run-quiet [ssh-opts conn remote-cmd &opt timeout]
  ((process/capture (ssh/args ssh-opts conn remote-cmd) (or timeout 30)) :status))

(defn ssh/slurp [ssh-opts conn remote-cmd &opt timeout]
  (string/trim (process/output (ssh/args ssh-opts conn remote-cmd) (or timeout 30))))

(defn ssh/slurp-args [ssh-opts conn remote-args]
  # Structured arbitrary commands are not readiness probes: no imposed deadline.
  (string/trim (process/output (ssh/command-args ssh-opts conn remote-args))))

(defn ssh/wait [ssh-opts conn timeout]
  (unless (and (number? timeout) (>= timeout 0) (< timeout math/inf))
    (error "SSH wait timeout must be a finite, nonnegative number"))
  (let [deadline (+ (os/clock :monotonic) timeout)]
    (var ready false)
    (while (and (not ready) (< (os/clock :monotonic) deadline))
      (when (and (= 0 (ssh/run-quiet ssh-opts conn "true"
                                    (max 0 (- deadline (os/clock :monotonic)))))
                 (< (os/clock :monotonic) deadline))
        (set ready true))
      (unless ready
        (ev/sleep (max 0 (min 3 (- deadline (os/clock :monotonic)))))))
    (unless ready
      (error (string/format "SSH did not become ready for %s within %v seconds" conn timeout)))
    true))
