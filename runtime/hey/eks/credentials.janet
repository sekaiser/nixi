# One credential contract for login and diagnostics. No output contains values.
(use hey)
(import hey/input)

(defn- without-line-ending [value]
  (cond
    (string/has-suffix? "\r\n" value) (slice value 0 (- (length value) 2))
    (string/has-suffix? "\n" value) (slice value 0 (- (length value) 1))
    value))

(defn- credential-value [value label]
  (when (or (empty? value) (string/find "\n" value)
            (string/find "\r" value) (string/find "\0" value))
    (error (string "SAML " label " must be one nonempty line")))
  (string value))

(defn username [file]
  (credential-value (without-line-ending (input/secret file)) "username"))

(defn read [username-file password-file format]
  (let [data (without-line-ending (input/secret password-file))
        separate? (and username-file (not (empty? username-file)))
        format (or format
                   # Older metadata omitted the format. Keep the compatibility
                   # rule in this shared boundary until the next rebuild.
                   (if (and (not separate?) (string/find "\n" data))
                     (do (file/write stderr "Legacy combined SAML credentials: configure passwordFileFormat = username-password before rebuilding.\n")
                         "username-password")
                     "password"))]
    (case format
      "password"
      {:username (when separate? (username username-file))
       :password (credential-value data "password")}
      "username-password"
      (do
        (when separate?
          (error "SAML username-password format cannot also set usernameFile"))
        (let [lines (string/split "\n" data)]
          (unless (= 2 (length lines))
            (error "SAML username-password format requires exactly two lines"))
          {:username (credential-value (without-line-ending (string (lines 0) "\n")) "username")
           :password (credential-value (lines 1) "password")}))
      (error "Unsupported SAML passwordFileFormat"))))
