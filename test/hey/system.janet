(use judge)
(use hey)
(import hey/system)

(deftest rollback-plans
  (test (system/rollback-commands "Linux" "/profile" "12")
        @[@["sudo" "nix-env" "--switch-generation" "12" "--profile" "/profile"]
          @["sudo" "/profile/bin/switch-to-configuration" "switch"]])
  (test (system/rollback-commands "Darwin" "/profile" "12")
        @[@["sudo" "darwin-rebuild" "--switch-generation" "12"]])
  (test (first (protect (system/rollback-commands "Linux" "/profile" "--help"))) false)
  (test (first (protect (system/rollback-commands "Unknown" "/profile" "12"))) false))

(deftest garbage-collection-plans
  (test (system/boot-refresh-commands "Darwin" "/profile") @[])
  (test (system/boot-refresh-commands "Linux" "/profile")
        @[@["sudo" "/profile/bin/switch-to-configuration" "boot"]]))
