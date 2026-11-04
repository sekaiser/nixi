;;; probe_emacs_certificates.el --- Opt-in GNU TLS path controls -*- lexical-binding: t; -*-
;; Run Emacs --batch --quick --no-site-file --load THIS SOURCE FIXTURE.
;; SOURCE is an absolute gnutls.el path, or "installed" for package libraries.
;; FIXTURE is a fresh local absolute directory prepared with denied/ and
;; readable/fixture.crt (synthetic text, never a TLS credential).
;; On Darwin wrap the process in sandbox-exec with an allow-default profile
;; that denies file-read-data for FIXTURE/denied only. Metadata stays visible.
;; Baseline source is expected to fail two literal-path cases; the proposal
;; must pass all nine. Actual wildcard denial must still signal a file-error.
;; No TLS handshake, certificate-content validation or default CI is claimed.
(setq native-comp-jit-compilation nil native-comp-enable-subr-trampolines nil)
(require 'cl-lib)
(require 'ert)
(defvar nixi-cert-source (pop command-line-args-left))
(defvar nixi-cert-root (pop command-line-args-left))
(unless (and (file-name-absolute-p nixi-cert-root)
             (not (file-remote-p nixi-cert-root))
             (or (equal nixi-cert-source "installed")
                 (and (file-name-absolute-p nixi-cert-source)
                      (not (file-remote-p nixi-cert-source)))))
  (error "Explicit local source/installed mode and absolute fixture are required"))
(defun nixi-cert-forbid-launch (&rest _)
  (error "Process/network operations forbidden in certificate path controls"))
(dolist (fn '(make-process make-network-process call-process call-process-region
              process-file start-process start-file-process open-network-stream))
  (advice-add fn :override #'nixi-cert-forbid-launch))
(if (equal nixi-cert-source "installed")
    (require 'gnutls)
  (load nixi-cert-source nil t t))
(defvar nixi-denied (expand-file-name "denied" nixi-cert-root))
(defvar nixi-readable (expand-file-name "readable/fixture.crt" nixi-cert-root))
(ert-deftest nixi-cert-literal-denied-directory-needs-no-enumeration ()
  (should-not (gnutls--get-files (list (expand-file-name "missing.crt" nixi-denied)))))
(ert-deftest nixi-cert-readable-literal-retained ()
  (should (equal (gnutls--get-files (list nixi-readable)) (list nixi-readable))))
(ert-deftest nixi-cert-readable-relative-literal-is-absolute ()
  (let ((default-directory (file-name-as-directory nixi-cert-root)))
    (should (equal (gnutls--get-files '("readable/fixture.crt")) (list nixi-readable)))))
(ert-deftest nixi-cert-real-glob-expands ()
  (should (equal (gnutls--get-files (list (expand-file-name "readable/*.crt" nixi-cert-root)))
                 (list nixi-readable))))
(ert-deftest nixi-cert-wildcard-denial-still-signals ()
  (should-error (gnutls--get-files (list (expand-file-name "*.crt" nixi-denied))) :type 'file-error))
(ert-deftest nixi-cert-callable-entry-preserved ()
  (should (equal (gnutls--get-files (list (lambda () nixi-readable)))
                 (list nixi-readable))))
(ert-deftest nixi-cert-invalid-nil-entry-still-signals ()
  (should-error (gnutls--get-files (list nil)) :type 'wrong-type-argument))
(ert-deftest nixi-cert-invalid-input-still-signals ()
  (should-error (gnutls--get-files '(42)) :type 'wrong-type-argument)
  (should-error (gnutls--get-files (list (lambda () (error "synthetic callback failure"))))
                :type 'error))
(ert-deftest nixi-cert-denied-literal-does-not-hide-next-readable-entry ()
  (should (equal (gnutls--get-files (list (expand-file-name "missing.crt" nixi-denied) nixi-readable))
                 (list nixi-readable))))
(ert-run-tests-batch-and-exit)
