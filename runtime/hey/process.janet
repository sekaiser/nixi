# Shared process execution. Callers choose capture (read-only probes) or run!
# (foreground commands, respecting hey's dry-run and exit handling).
(use hey)
(import ./subprocess)
(def capture subprocess/capture)
(def output subprocess/output)

(defn probe [args &opt timeout output-limit]
  # Diagnostics must always be bounded; callers may select a longer deadline.
  # capture/output remain available for builds without a short probe timeout.
  (default timeout 10)
  (unless (and (number? timeout) (> timeout 0) (< timeout math/inf))
    (error "Probe timeout must be a finite positive number"))
  (capture args timeout output-limit))

(def run! execute!)

(defn watch! [root extensions command]
  (unless (dryrun?)
    (unless (path/directory? root)
      (abort "Watch directory does not exist: %s" root))
    (unless (path/find "watchexec")
      (abort "watchexec is not available on PATH. Enable hey.development or install watchexec.")))
  # Watchexec otherwise joins argv into shell source, including project paths.
  (run! @["watchexec" "--restart" "--shell=none" "--watch" root
          ;(if extensions ["--exts" extensions] []) "--" ;command]))

(defn temporary-directory [label]
  # mktemp creates the directory atomically; never reuse predictable paths.
  (string/trim (output @["mktemp" "-d"
                         (path/join (or (os/getenv "TMPDIR") "/tmp")
                                    (string label ".XXXXXXXXXX"))])))
