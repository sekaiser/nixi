# The installed VM retention contract. JSON keys are strings, not keywords.
(import spork/json)
(import ./generation-policy)

(def validate-keep generation-policy/validate-keep)

(defn decode [source]
  (def info (json/decode source))
  (unless (dictionary? info)
    (error "Remote hey metadata must be a JSON object"))
  (def profiles (get info "profiles" {}))
  (unless (dictionary? profiles)
    (error "Remote hey profiles metadata must be a JSON object"))
  (def profile (get profiles "vm-image"))
  (unless (nil? profile)
    (unless (dictionary? profile)
      (error "Remote vm-image metadata must be a JSON object"))
    # Accept the legacy unversioned contract, but never guess at future ones.
    (unless (= 1 (get profile "schemaVersion" 1))
      (error "Unsupported remote vm-image metadata schemaVersion; update hey"))
    (unless (boolean? (get profile "enable"))
      (error "Remote vm-image metadata requires a boolean enable field"))
    (when (get profile "enable")
      (unless (boolean? (get profile "autoCleanGenerations"))
        (error "Remote vm-image metadata requires a boolean autoCleanGenerations field"))
      {:auto-clean (get profile "autoCleanGenerations")
       :keep (validate-keep (get profile "keepGenerations"))})))

(defn automatic-keep [policy override]
  # An override changes the count, never grants permission for auto-cleanup.
  (when (get policy :auto-clean)
    (validate-keep (or override (policy :keep)))))

(defn manual-keep [policy override]
  (validate-keep (or override (get policy :keep) 3)))
