# Pure retention policy, shared by local profiles and VM metadata validation.
(defn validate-keep [keep]
  (unless (and (int? keep) (> keep 0))
    (error "keep-generations must be a positive 32-bit integer"))
  keep)

(defn plan [generations current keep]
  (validate-keep keep)
  (unless (and (every? (map |(and (int? $) (> $ 0)) generations))
               (= (length generations) (length (distinct generations)))
               (int? current) (index-of current generations))
    (error "Cannot plan retention without unique generation numbers and an active generation"))
  # A rolled-back active generation counts toward N. Gaps do not count.
  (let [others (reverse (sort (filter |(not= $ current) generations)))
        retained (sort @[current ;(slice others 0 (min (- keep 1) (length others)))])]
    {:keep retained
     :delete (sort (filter |(nil? (index-of $ retained)) generations))}))
