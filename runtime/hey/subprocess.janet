# Core-only bridge to the Nix-built supervisor; safe during Hey bootstrap.
(def- cleanups @{})

(defn cleanup-all []
  (eachk cleanup cleanups (cleanup)))

(defn- read-exact [stream count]
  (def data @"")
  (while (< (length data) count)
    (unless (ev/read stream (- count (length data)) data)
      (error "Capture supervisor ended without a complete result")))
  data)

(defn- read-result [stream limit timeout]
  (unless (= "NXSP1\n" (string (read-exact stream 6)))
    (error "Unsupported capture supervisor protocol; rebuild Hey"))
  (def out @"")
  (def err @"")
  (var result nil)
  (while (nil? result)
    (let [header (read-exact stream 5)
          size (+ (* (header 1) 16777216) (* (header 2) 65536) (* (header 3) 256) (header 4))]
      (unless (<= size 65536) (error "Invalid capture supervisor frame"))
      (def payload (read-exact stream size))
      (case (header 0)
        79 (do
             (when (> (+ (length out) size) limit) (error "Invalid supervisor output limit"))
             (buffer/push-string out payload))
        69 (do
             (when (> (+ (length err) size) limit) (error "Invalid supervisor output limit"))
             (buffer/push-string err payload))
        82 (let [fields (string/split " " payload)
                 values (map scan-number fields)
                 [status reason exec-errno] values]
             (unless (and (= 3 (length values)) (every? (map int? values))
                          (<= 0 status 255) (<= 0 reason 5) (>= exec-errno 0))
               (error "Invalid capture supervisor result"))
             (when (= reason 4)
               (errorf "Captured command could not be started (errno %d)" exec-errno))
             (set result {:out (if (= reason 0) (string/trimr out) "")
                      :err (case reason
                             0 (string/trimr err)
                             1 (string "timed out after " timeout " seconds")
                             2 (string "captured output exceeded " limit " bytes per stream")
                             (string "capture supervision failed; a child or output stream did not terminate cleanly (errno " exec-errno ")"))
                      :status status :timeout (= reason 1)}))
        (error "Invalid capture supervisor frame type"))))
  result)

(defn capture [args &opt timeout output-limit inherit-stderr?]
  (default output-limit (* 8 1024 1024))
  (unless (and (int? output-limit) (> output-limit 0))
    (error "Capture output limit must be a positive integer"))
  (when (and timeout (not (and (number? timeout) (> timeout 0) (< timeout math/inf))))
    (error "Capture timeout must be a finite positive number"))
  (def helper (or (os/getenv "HEY_PROCESS_SUPERVISOR") "nixi-process-supervisor"))
  (with [proc (os/spawn [helper "--limit" (string output-limit) "--timeout" (string (or timeout 0))
                        ;(if inherit-stderr? ["--inherit-stderr"] []) "--" ;args]
                       :p {:in :pipe :out :pipe :err stderr})]
    (var done false)
    (var cancelling false)
    (defn cleanup [&]
      (unless (or done cancelling)
        (set cancelling true)
        # EOF is also delivered by the kernel if Hey is killed abruptly. Do
        # not SIGKILL the supervisor: it must finish its bounded group cleanup.
        (try (ev/close (proc :in)) ([err fib] nil))
        (try (os/proc-wait proc) ([err fib] nil))))
    (put cleanups cleanup true)
    (defer (do (put cleanups cleanup nil) (cleanup))
      (let [result (read-result (proc :out) output-limit timeout)
            status (os/proc-wait proc)]
        (set done true)
        (unless (= status 0) (error "Capture supervisor failed before completing cleanup"))
        result))))

(defn output [args &opt timeout output-limit inherit-stderr?]
  (let [result (capture args timeout output-limit inherit-stderr?)]
    (unless (= 0 (result :status))
      (errorf "%s failed with exit code %d: %s"
              (string/join args " ") (result :status) (result :err)))
    (result :out)))
