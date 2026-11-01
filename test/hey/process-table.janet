(use judge)
(import hey/process-table)

(deftest explicit-process-fields
  (test (process-table/fields "  123  1 Ss  01:02 ssh -N example.invalid")
        {:pid "123" :ppid "1" :stat "Ss" :etime "01:02" :command "ssh -N example.invalid"})
  (test (process-table/fields "123\t42\tS\t1-02:03:04\t/path with spaces/command arg")
        {:pid "123" :ppid "42" :stat "S" :etime "1-02:03:04" :command "/path with spaces/command arg"})
  (each row ["PID PPID STAT ELAPSED COMMAND" "123 1 S" "alice 123 0 0 0 0 ?? S 00:00 0:00 ssh host"]
    (test ((process-table/checked-result {:status 0 :out row :err ""}) :status) 1))
  (test (process-table/checked-result {:status 42 :out "partial" :err "failure"})
        {:status 42 :out "partial" :err "failure"})
  (test ((process-table/checked-result {:status 0 :out "\n" :err ""}) :status) 0))
