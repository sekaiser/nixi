(use judge)
(import hey/generation-policy :as policy)

(deftest retention-planning
  (test (policy/plan [1 3 7 12] 3 2) {:keep @[3 12] :delete @[1 7]})
  (test (policy/plan [12 3 1 7] 12 1) {:keep @[12] :delete @[1 3 7]})
  (test (policy/plan [1 3] 1 10) {:keep @[1 3] :delete @[]})
  (each keep [0 -1 1.5 math/inf math/nan nil "10" 2147483648]
    (test (first (protect (policy/plan [1 2] 2 keep))) false))
  (each [generations current] [[[] 1] [[1 1] 1] [[1 2] 3] [[0 1] 1] [[1 "2"] 1]]
    (test (first (protect (policy/plan generations current 1))) false)))
