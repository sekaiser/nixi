(import spork/path)
(import ./lib)

(def- held @{})

(defn acquire
  "Atomically acquire a directory lock and return an idempotent release function.
  Stale locks are never stolen; a bounded wait reports the path for recovery."
  [file &opt timeout]
  (default timeout 30)
  (when (get held file)
    (errorf "Lock already held by this process: %s" file))
  (lib/path/mkdirp (path/dirname file))
  (def deadline (+ (os/clock :monotonic) timeout))
  (while (not (os/mkdir file))
    (when (>= (os/clock :monotonic) deadline)
      (errorf "Timed out waiting for lock: %s. Check for a running hey process before removing a stale lock." file))
    (os/sleep 0.05))
  (put held file true)
  (var active true)
  (fn [&]
    (when active
      (os/rmdir file)
      (put held file nil)
      (set active false))))
