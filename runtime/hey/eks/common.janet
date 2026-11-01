# Shared EKS metadata, presentation and command arguments.
(use hey)
(import hey/process)

(defn config-file []
  (path/xdg :config "hey/aws.json"))

(defn- nullable-string! [record key]
  (let [value (get record key)]
    (unless (or (nil? value) (string? value))
      (abort "AWS metadata %s must be a string or null" key))))

(defn- cluster-key! [key]
  (unless (and (string? key)
               (peg/match '(sequence (some (choice (range "az" "AZ" "09") (set "_-"))) -1) key))
    (abort "EKS cluster keys must contain only letters, digits, underscores or hyphens"))
  key)

(defn- decode-config [source]
  # Nix emits optional fields as JSON null. Decode them to Janet nil once,
  # at the boundary, without conflating explicit false with missing values.
  (let [data (json/decode source false true)
        cfg (when (dictionary? data) (get data "awscli2"))]
    (unless (dictionary? cfg)
      (abort "AWS metadata must contain an awscli2 object"))
    (unless (= 1 (get cfg "schemaVersion" 1))
      (abort "Unsupported AWS metadata schemaVersion; update hey"))
    (each key ["samlEnabled" "eksEnabled"]
      (unless (or (nil? (get cfg key)) (boolean? (get cfg key)))
        (abort "AWS metadata %s must be a boolean" key)))
    (each key ["samlAccounts" "ssoProfiles"]
      (let [values (get cfg key [])]
        (unless (and (indexed? values) (every? (map string? values)))
          (abort "AWS metadata %s must be an array of strings" key))))
    (each [key fields] (pairs {"samlAccountDetails" ["usernameFile" "passwordFile" "passwordFileFormat" "awsProfile"]
                              "eksClusters" ["name" "profile" "region" "kubeContext" "bastion" "vpnService" "namespace"]})
      (let [records (get cfg key {})]
        (unless (dictionary? records)
          (abort "AWS metadata %s must be an object" key))
        (each [name record] (pairs records)
          (when (= key "eksClusters") (cluster-key! name))
          (unless (dictionary? record)
            (abort "AWS metadata %s.%s must be an object" key name))
          (each field fields (nullable-string! record field))
          (when (= key "samlAccountDetails")
            (unless (index-of (get record "passwordFileFormat") [nil "password" "username-password"])
              (abort "Unsupported SAML passwordFileFormat")))
          (when (= key "eksClusters")
            (each field ["name" "profile"]
              (unless (and (string? (get record field)) (not (empty? (get record field))))
                (abort "EKS cluster metadata requires nonempty %s" field)))))))
    data))

(defn aws-config []
  (let [file (config-file)]
    (unless (= :file (os/stat file :mode))
      (abort "hey eks is not available on this host; enable modules.shell.awscli2 to generate %s" file))
    (decode-config (slurp file))))

(defn clusters []
  (or (get-in (aws-config) ["awscli2" "eksClusters"]) @{}))

(defn saml-accounts []
  (let [cfg ((aws-config) "awscli2")]
    (if (= false (cfg "samlEnabled"))
      @[]
      (or (cfg "samlAccounts") @[]))))

(defn sso-profiles []
  (or (get-in (aws-config) ["awscli2" "ssoProfiles"]) @[]))

(defn saml-account-details []
  (or (get-in (aws-config) ["awscli2" "samlAccountDetails"]) @{}))

(defn saml-account-for-profile [profile]
  (find |(= profile (or (get-in (saml-account-details) [$ "awsProfile"]) $))
        (saml-accounts)))

(defn cluster-label [key cluster]
  (string key
          " profile=" (cluster "profile")
          " name=" (cluster "name")
          " region=" (or (cluster "region") "-")
          " context=" (or (cluster "kubeContext") "-")
          " bastion=" (or (cluster "bastion") "-")))

(defn find-cluster [name]
  (let [configured (clusters)]
    (or (when-let [cluster (configured name)]
          [name cluster])
        (let [matches (filter |(= name ((in $ 1) "name")) (pairs configured))]
          (case (length matches)
            0 (abort "Unknown EKS cluster: %s" name)
            1 (first matches)
            (abort "Ambiguous EKS cluster: %s; use an explicit key: %s"
                   name (string/join (sort (map first matches)) ", ")))))))

(defn command-exists? [command]
  (truthy? (path/find command)))

(defn current-host []
  (or (flake :host) ""))

(defn opt-str [value]
  (when (and (string? value) (not (empty? value)))
    value))

(def eol "\n")

(defn success [label]
  (file/write stderr (string "\e[32m✓ " label "\e[0m" eol))
  (file/flush stderr)
  true)

(defn failure [label &opt detail]
  (file/write stderr (string "\e[31m𐄂 " label "\e[0m" eol))
  (when (and detail (not (empty? detail)))
    (file/write stderr (string detail eol)))
  (file/flush stderr)
  false)

(defn warning [label &opt detail]
  (file/write stderr (string "\e[33m⚠ " label "\e[0m" eol))
  (when (and detail (not (empty? detail)))
    (file/write stderr (string detail eol)))
  (file/flush stderr)
  true)

(defn line [text]
  (file/write stdout (string text eol))
  (file/flush stdout))

(def command-result process/capture)

(defn command-detail [result]
  (let [err (result :err)
        out (result :out)]
    (cond
      (and err (not (empty? err))) err
      (and out (not (empty? out))) out
      "")))

(defn require-command [label args timeout]
  (if (dryrun?)
    (do
      (file/write stdout (string "DRYRUN: " (string/join args " ") "\n"))
      true)
    (let [result (command-result args timeout)]
      (if (= 0 (result :status))
        (success label)
        (do
          (failure label (command-detail result))
          false)))))

(def run process/run!)

(defn kubeconfig-dir []
  (path/xdg :config "hey/eks/kubeconfigs"))

(defn kubeconfig-path [cluster-key]
  (path/join (kubeconfig-dir) (string (cluster-key! cluster-key) ".yaml")))

(defn cluster-context [cluster]
  (or (opt-str (cluster "kubeContext")) (cluster "name")))

(defn aws-identity-args [cluster]
  @["aws" "sts" "get-caller-identity" "--profile" (cluster "profile")])

(defn aws-identity-json-args [cluster]
  @["aws" "sts" "get-caller-identity" "--profile" (cluster "profile") "--output" "json"])

(defn aws-expiration-args [cluster]
  @["aws" "configure" "get" "aws_session_expiration" "--profile" (cluster "profile")])

(defn command-out-or-nil [args timeout]
  (if (dryrun?)
    (do
      (file/write stdout (string "DRYRUN: " (string/join args " ") "\n"))
      nil)
    (let [result (command-result args timeout)
          out (result :out)]
      (when (and (= 0 (result :status)) (not (empty? out)))
        out))))

(defn kubectl-cluster-info-args [cluster-key cluster]
  @["kubectl"
    "--kubeconfig" (kubeconfig-path cluster-key)
    "--context" (cluster-context cluster)
    "get" "--raw=/readyz" "--request-timeout=30s"])

(defn kubectl-use-context-args [cluster-key cluster]
  @["kubectl"
    "--kubeconfig" (kubeconfig-path cluster-key)
    "config" "use-context" (cluster-context cluster)])

(defn local-bastion-for-cluster? [cluster]
  (let [bastion (opt-str (cluster "bastion"))]
    (and bastion (= bastion (current-host)))))

(defn cluster-vpn-service [cluster]
  (or (opt-str (cluster "vpnService")) "openvpn-eks.service"))

(defn valid-vpn-action? [action]
  (not (nil? (index-of action ["status" "start" "restart" "logs"]))))

(defn eks-list []
  (let [configured (clusters)]
    (if (empty? configured)
      (echo "No EKS clusters configured.")
      (each [key cluster] (sort (pairs configured))
        (echo (cluster-label key cluster))))))

(defn port-forward-local-port [mapping]
  (let [parts (string/split ":" mapping)]
    (if (= 2 (length parts))
      (get parts 0)
      (abort "Port mapping must be LOCAL:REMOTE, got: %s" mapping))))

(defn validate-port-forward-args [mapping namespace-mode]
  (port-forward-local-port mapping)
  (when (= namespace-mode "all")
    (abort "Port-forward requires a single namespace; use default or an explicit namespace.")))
