;;; probe_emacs_default_certificates.el --- Opt-in Darwin build preflight -*- lexical-binding: t; -*-
;; Run an existing Emacs 31.1 inside the ordinary Darwin Nix build sandbox:
;; --batch --quick --no-site-file --load THIS GNUTLS-SOURCE baseline|corrected
;; Use a fresh synthetic HOME. GNUTLS-SOURCE is an absolute local GNU source
;; filename. This clears the cached variable and loads the exact reviewed
;; 11-entry GNU default initializer before testing selection and Smime/Org.
;; The baseline failure expectation applies to the reviewed Darwin sandbox's
;; inaccessible host CA directories. This is opt-in evidence, not default CI.
;; No CA contents, TLS handshake, subprocess or network operation is needed.
(setq native-comp-jit-compilation nil native-comp-enable-subr-trampolines nil)
(require 'json)
(defvar nixi-default-source (pop command-line-args-left))
(defvar nixi-default-expected (pop command-line-args-left))
(unless (and (equal emacs-version "31.1")
             (stringp nixi-default-source)
             (file-name-absolute-p nixi-default-source)
             (not (file-remote-p nixi-default-source))
             (member nixi-default-expected '("baseline" "corrected")))
  (error "Explicit GNU 31.1 source and baseline/corrected expectation required"))
(defun nixi-default-forbid-launch (&rest _)
  (error "Process/network operations forbidden in the default CA preflight"))
(dolist (fn '(make-process make-network-process call-process call-process-region
              process-file start-process start-file-process open-network-stream))
  (advice-add fn :override #'nixi-default-forbid-launch))
(dolist (feature '(smime org-element ox ox-texinfo))
  (when (featurep feature)
    (error "Load-chain feature was preloaded: %S" feature)))
(makunbound 'gnutls-trustfiles)
(load nixi-default-source nil t t)
(unless (and (= (length gnutls-trustfiles) 11)
             (equal (secure-hash 'sha256 (prin1-to-string gnutls-trustfiles))
                    "43dd91fc11b7f8dc4ef216ba323b3e382ec7628b6443db7a741cb9ca6f6fcfb1"))
  (error "The exact reviewed GNU 31.1 default initializer is required"))
(let* ((selected-count nil)
       (trust-result
        (condition-case nil
            (progn (setq selected-count (length (gnutls-trustfiles))) "passed")
          (file-error "file-error")))
       (load-result
        (condition-case err
            (progn (require 'smime) (require 'org-element)
                   (require 'ox) (require 'ox-texinfo) "passed")
          (error (symbol-name (car err))))))
  (unless (if (equal nixi-default-expected "baseline")
              (and (equal trust-result "file-error")
                   (not (equal load-result "passed")))
            (and (equal trust-result "passed") (equal load-result "passed")))
    (error "Unexpected preflight outcome: selection=%S loads=%S"
           trust-result load-result))
  (princ (json-encode
          (list (cons 'label nixi-default-expected)
                (cons 'defaultTrustfiles trust-result)
                (cons 'gnuDefaultEntries (length gnutls-trustfiles))
                (cons 'gnuDefaultListSha256
                      (secure-hash 'sha256 (prin1-to-string gnutls-trustfiles)))
                (cons 'selectedCandidateCount selected-count)
                (cons 'smimeAndOrgLoads load-result)))))
