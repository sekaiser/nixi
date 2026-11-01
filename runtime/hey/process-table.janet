# One explicit ps format for all local process diagnostics. No aux heuristics.
(import ./process)

(def argv ["ps" "-ax" "-o" "pid=,ppid=,stat=,etime=,command="])

(defn fields [line]
  (let [parts (peg/match '(sequence (any (set " \t"))
                           (<- (some (range "09"))) (some (set " \t"))
                           (<- (some (range "09"))) (some (set " \t"))
                           (<- (some (if-not (set " \t") 1))) (some (set " \t"))
                           (<- (some (if-not (set " \t") 1))) (some (set " \t"))
                           (<- (some 1)) -1) line)]
    (unless parts (error "Process table probe failed: malformed process row"))
    (let [[pid ppid stat etime command] parts]
      {:pid pid :ppid ppid :stat stat :etime etime :command command})))

(defn checked-result [result]
  (if (not= 0 (result :status))
    result
    (try
      (do
        (each line (string/split "\n" (result :out))
          (unless (empty? (string/trim line)) (fields line)))
        result)
      ([err fib]
       # Never echo arbitrary process arguments from a malformed snapshot.
       {:status 1 :out "" :err "Process table probe failed: malformed process row"}))))

(defn snapshot []
  (checked-result (process/probe argv 10)))
