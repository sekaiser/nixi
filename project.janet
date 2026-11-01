(declare-project
 :name "nixi"
 :author "Nixi contributors"
 :description "Reusable Nix host framework and hey CLI"
 :license "MIT")

(put-in (getrules) ["test" :recipe] @[]) # Disable build-in tests
(task "test" []
  (protect (shell "bin/hey" "check" "unit")))
