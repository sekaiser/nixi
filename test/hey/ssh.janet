(use judge)
(use hey/ssh)

(deftest ssh-structured-arguments
  (test (ssh/command-args ["-t"] "alice@192.0.2.1"
          ["hey" "eks" "logs" "review" "api|worker" "" "it's quoted"])
        @["ssh" "-t" "alice@192.0.2.1"
          "'hey' 'eks' 'logs' 'review' 'api|worker' '' 'it'\"'\"'s quoted'"])
  (test (ssh/command-args [] "alice@192.0.2.1" [])
        @["ssh" "alice@192.0.2.1"]))

(deftest ssh-trust-options
  (def opts (ssh/trusted-options))
  (test (not (nil? (index-of "StrictHostKeyChecking=yes" opts))) true)
  (test (not (nil? (index-of "BatchMode=yes" opts))) true)
  (test (not (nil? (index-of "UpdateHostKeys=no" opts))) true)
  (test (ssh/args [] "alice@192.0.2.1" "true")
        @["ssh" "alice@192.0.2.1" "true"])
  (test (ssh/interactive-options)
        @["-o" "StrictHostKeyChecking=ask" "-o" "UpdateHostKeys=no"]))
