(use hey)
(import hey/process)
(defn- run [args] (process/probe args 30))

(defn check-command [label args]
  (let [result (run args)]
    (if (= 0 (result :status))
      (do
        (echof :check "%s" label)
        true)
      (do
        (echof :error "%s failed" label)
        (echof :err "command: %s" (string/join args " "))
        (when (not (empty? (result :err)))
          (echo :err (result :err)))
        (when (not (empty? (result :out)))
          (echo :err (result :out)))
        false))))

(defn check-command-output-contains [label args & needles]
  (let [result (run args)
        output (string (result :out) "\n" (result :err))]
    (if (and (= 0 (result :status))
             (all |(string/find $ output) needles))
      (do
        (echof :check "%s" label)
        true)
      (do
        (echof :error "%s failed" label)
        (echof :err "command: %s" (string/join args " "))
        (when (not (= 0 (result :status)))
          (echof :err "exit status: %d" (result :status)))
        (each needle needles
          (unless (string/find needle output)
            (echof :err "missing output: %s" needle)))
        (when (not (empty? output))
          (echo :err output))
        false))))

(defn check-command-output-contains-not [label args needles forbidden]
  (let [result (run args)
        output (string (result :out) "\n" (result :err))
        has-needles (all |(string/find $ output) needles)
        has-forbidden (truthy? (find |(string/find $ output) forbidden))]
    (if (and (= 0 (result :status)) has-needles (not has-forbidden))
      (do
        (echof :check "%s" label)
        true)
      (do
        (echof :error "%s failed" label)
        (echof :err "command: %s" (string/join args " "))
        (when (not (= 0 (result :status)))
          (echof :err "exit status: %d" (result :status)))
        (each needle needles
          (unless (string/find needle output)
            (echof :err "missing output: %s" needle)))
        (each needle forbidden
          (when (string/find needle output)
            (echof :err "forbidden output: %s" needle)))
        (when (not (empty? output))
          (echo :err output))
        false))))

(defn check-command-fails-output-contains [label args & needles]
  (let [result (run args)
        output (string (result :out) "\n" (result :err))]
    (if (and (not= 0 (result :status))
             (all |(string/find $ output) needles))
      (do
        (echof :check "%s" label)
        true)
      (do
        (echof :error "%s failed" label)
        (echof :err "command: %s" (string/join args " "))
        (echof :err "exit status: %d" (result :status))
        (each needle needles
          (unless (string/find needle output)
            (echof :err "missing output: %s" needle)))
        (when (not (empty? output))
          (echo :err output))
        false))))
