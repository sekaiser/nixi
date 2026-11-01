# Read-only probes: no VPN startup or kubeconfig initialization in this module.
(use hey)
(use hey/eks/common)
(import ./credentials)

(defn- aws-identity-info [cluster]
  (when-let [out (command-out-or-nil (aws-identity-json-args cluster) 15)]
    (ignore-errors (json/decode out))))

(defn- aws-session-expiration [cluster]
  (command-out-or-nil (aws-expiration-args cluster) 5))

(defn- print-credential-status [cluster]
  (echo (string "profile: " (cluster "profile")))
  (if-let [identity (aws-identity-info cluster)]
    (do
      (when-let [account (identity "Account")]
        (echo (string "aws-account: " account)))
      (when-let [arn (identity "Arn")]
        (echo (string "aws-arn: " arn))))
    (unless (dryrun?)
      (echo "aws-identity: unavailable")))
  (echo (string "credential-expiration: " (or (aws-session-expiration cluster) "unknown"))))

(defn- placeholder-secret? [value]
  (not (nil? (string/find "CHANGE_ME" value))))

(defn- check-saml-secret-files [cluster]
  (let [account (saml-account-for-profile (cluster "profile"))
        details ((saml-account-details) account)
        username-file (opt-str (get details "usernameFile"))
        password-file (opt-str (get details "passwordFile"))]
    (if (dryrun?)
      (do (line "DRYRUN: validate declared SAML credential files") true)
      (try
        (let [values (if password-file
                        (credentials/read username-file password-file (get details "passwordFileFormat"))
                        {:username (credentials/username username-file)})]
          (if (some placeholder-secret? (filter string? [(values :username) (values :password)]))
            (failure "SAML credential files contain a placeholder")
            (success "SAML credential files satisfy the login input contract")))
        # The boundary may report a path/read/decoder error. Do not forward it:
        # this diagnostic only needs the non-secret validation outcome.
        ([err fib] (failure "SAML credential files failed validation"
                            "Require readable UTF-8 regular files, at most 64 KiB each, matching passwordFileFormat (five-second reads)."))))))

(defn- saml-backed-cluster? [cluster]
  (truthy? (saml-account-for-profile (cluster "profile"))))

(defn- diagnostic-preflight [key cluster]
  (var ok true)
  (when (local-bastion-for-cluster? cluster)
    (when-let [service (opt-str (cluster "vpnService"))]
      (unless (require-command (string "VPN service is active: " service)
                @["systemctl" "is-active" "--quiet" service] 10)
        (warning "Start the VPN explicitly" (string "Run: hey eks vpn start " key))
        (set ok false))))
  (unless (require-command "AWS identity is reachable" (aws-identity-args cluster) 15)
    (set ok false))
  (if (or (dryrun?) (= :file (os/stat (kubeconfig-path key) :mode)))
    (unless (require-command "Kubernetes API is reachable"
              (kubectl-cluster-info-args key cluster) 45)
      (warning "Check network access and refresh kubeconfig if needed"
               (string "Run: hey eks kubeconfig " key))
      (set ok false))
    (do
      (failure "EKS kubeconfig is missing" (string "Run: hey eks kubeconfig " key))
      (set ok false)))
  ok)

(defn eks-preflight [cluster-key cluster &opt skip-aws?]
  (var ok true)
  (when (not skip-aws?)
    (unless (require-command "AWS identity is reachable" (aws-identity-args cluster) 15)
      (set ok false)))
  (unless (require-command "Kubernetes API is reachable" (kubectl-cluster-info-args cluster-key cluster) 45)
    (set ok false))
  ok)

(defn eks-status [cluster-name]
  (let [[key cluster] (find-cluster cluster-name)]
    (echo (string "cluster: " key))
    (echo (string "name: " (cluster "name")))
    (echo (string "profile: " (cluster "profile")))
    (echo (string "region: " (or (opt-str (cluster "region")) "-")))
    (echo (string "context: " (cluster-context cluster)))
    (echo (string "kubeconfig: " (kubeconfig-path key)))
    (echo (string "bastion: " (or (opt-str (cluster "bastion")) "-")))
    (echo (string "vpn-service: " (or (opt-str (cluster "vpnService")) "-")))
    (when-let [namespace (opt-str (cluster "namespace"))]
      (echo (string "namespace: " namespace)))
    (print-credential-status cluster)
    (var ok true)
    (unless (diagnostic-preflight key cluster)
      (set ok false))
    (unless ok
      (exit 1))))

(defn eks-credentials [cluster-name]
  (let [[_ cluster] (find-cluster cluster-name)]
    (print-credential-status cluster)
    (unless (require-command "AWS identity is reachable" (aws-identity-args cluster) 15)
      (exit 1))))

(defn eks-doctor [&opt cluster-name]
  (var ok true)
  (let [cfg ((aws-config) "awscli2")
        selected (when cluster-name (find-cluster cluster-name))
        commands @["aws"]]
    (success (string "AWS host config exists at " (config-file)))
    (unless (= false (cfg "eksEnabled"))
      (array/concat commands ["kubectl" "k9s" "stern"]))
    (when (if selected
            (saml-backed-cluster? (selected 1))
            (not (empty? (saml-accounts))))
      (array/push commands "saml2aws"))
    (each command commands
      (if (command-exists? command)
        (success (string command " is available"))
        (do
          (set ok false)
          (failure (string command " is available")))))
    (if selected
      (let [[key cluster] selected]
        (success (string "EKS cluster is configured: " key))
        (line (cluster-label key cluster))
        (when-let [account (saml-account-for-profile (cluster "profile"))]
          (let [details ((saml-account-details) account)]
            (if (or (opt-str (get details "usernameFile"))
                    (opt-str (get details "passwordFile")))
              (unless (check-saml-secret-files cluster)
                (set ok false))
              (warning "SAML secret files are not declared on this host"
                       "Login may still work interactively or on the bastion."))))
        (unless (diagnostic-preflight key cluster)
          (set ok false)))
      (eks-list)))
  (unless ok (exit 1)))
