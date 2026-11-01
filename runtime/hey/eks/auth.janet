# Explicit provider selection and login; credential files are read only at execution.
(use hey)
(use hey/eks/common)
(import ./credentials)

(defn- saml-account-password-file [account]
  (get-in (saml-account-details) [account "passwordFile"]))

(defn- saml-account-username-file [account]
  (get-in (saml-account-details) [account "usernameFile"]))

(defn- run-saml2aws-login [account credentials &opt skip-prompt? clean?]
  (let [args @["saml2aws" "login" "-a" account]]
    (when skip-prompt?
      (array/push args "--skip-prompt"))
    (with-envvars ["SAML2AWS_USERNAME" (get credentials :username)
                   "SAML2AWS_PASSWORD" (get credentials :password)]
      (if clean?
        (execute-clean args)
        (run args)))))

(defn- resolve-login [name]
  (let [saml (saml-accounts)
        sso (sso-profiles)
        candidates [;saml ;sso]
        resolved (or name
                     (if (= 1 (length candidates))
                       (first candidates)
                       (abort "Pass a configured SAML account or SSO profile. Available: %s"
                              (if (empty? candidates) "(none; check or rebuild AWS configuration)"
                                (string/join candidates ", ")))))
        saml? (not (nil? (index-of resolved saml)))
        sso? (not (nil? (index-of resolved sso)))]
    (cond
      (and saml? sso?)
      (abort "Login name %s matches both SAML and SSO; rename one in the host configuration." resolved)
      saml? [:saml resolved]
      sso? [:sso resolved]
      (abort "Unknown login account/profile: %s. Rebuild after changing AWS configuration." resolved))))

(defn eks-login [&opt account]
  (let [[provider resolved] (resolve-login account)]
    (if (= provider :sso)
      (run @["aws" "sso" "login" "--profile" resolved])
      (let [username-file (saml-account-username-file resolved)
            password-file (saml-account-password-file resolved)
            format (get-in (saml-account-details) [resolved "passwordFileFormat"])]
        (if (opt-str password-file)
          # Never open credential files for a preview (including missing files/FIFOs).
          (if (dryrun?)
            (run @["saml2aws" "login" "-a" resolved "--skip-prompt"])
            (let [credentials (credentials/read username-file password-file format)
                  status (run-saml2aws-login resolved credentials true true)]
              (unless (= 0 status)
                (file/write stderr "Stored SAML password login failed; retrying interactively.\n")
                (run-saml2aws-login resolved {:username (credentials :username)} false false))))
          (run @["saml2aws" "login" "-a" resolved]))))))
