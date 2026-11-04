;;; probe_flymake_backends.el --- Opt-in backend trust controls -*- lexical-binding: t; -*-
;; Run Emacs --batch --quick --no-site-file --load THIS SOURCE_OR_--installed
;;   ABSOLUTE_SYNTHETIC_FILE. Use a fresh synthetic HOME and fixture file.
;; --installed requires normal compiled Flymake libraries, without changing
;; load-path or loading source. Select the intended package paths explicitly
;; before this probe when testing a composed distribution.
;; Source mode is a separate review control; neither mode loads user init,
;; launches diagnostic tools or establishes full consumer acceptance.
;; SPDX-License-Identifier: GPL-3.0-or-later
(setq native-comp-jit-compilation nil native-comp-enable-subr-trampolines nil
      enable-local-variables nil enable-local-eval nil create-lockfiles nil)
(require 'ert)
(require 'cl-lib)
(defvar nixi-source (pop command-line-args-left))
(defvar nixi-fixture (pop command-line-args-left))
(defvar nixi-launches nil)
(defun nixi-no-launch (op &rest _) (push op nixi-launches) (error "Launch forbidden"))
(dolist (fn '(make-process make-network-process call-process call-process-region
              process-file start-process start-file-process open-network-stream))
  (advice-add fn :override (apply-partially #'nixi-no-launch fn)))
(unless (and (file-name-absolute-p nixi-fixture)
             (not (file-remote-p nixi-fixture))
             (file-regular-p nixi-fixture))
  (error "An existing absolute local synthetic fixture file is required"))
(if (equal nixi-source "--installed")
    (progn
      (unless (string-suffix-p ".elc" (or (locate-library "flymake") ""))
        (error "Installed mode requires compiled Flymake"))
      (require 'flymake)
      (unless (string-suffix-p ".elc" (or (symbol-file 'flymake--run-backend 'defun) ""))
        (error "Installed mode forbids a source-loaded Flymake override")))
  (unless (and (file-name-absolute-p nixi-source) (not (file-remote-p nixi-source)))
    (error "An absolute local source file or --installed is required"))
  (require 'flymake)
  (load nixi-source nil t t))
(defvar-local nixi-ordinary-calls 0)
(defvar-local nixi-safe-calls 0)
(defun nixi-ordinary-backend (report &rest _)
  (cl-incf nixi-ordinary-calls) (funcall report nil))
(defun nixi-safe-backend (report &rest _)
  (cl-incf nixi-safe-calls) (funcall report nil))
(function-put 'nixi-safe-backend 'flymake-always-safe t)
(defmacro nixi-with-local-file (&rest body)
  `(with-temp-buffer
     (setq buffer-file-name nixi-fixture buffer-file-truename (file-truename nixi-fixture))
     (insert "synthetic local content\n")
     (setq-local trusted-content nil untrusted-content nil
                 flymake-diagnostic-functions '(nixi-ordinary-backend)
                 flymake-no-changes-timeout nil flymake-start-on-flymake-mode nil)
     (flymake-mode 1)
     (unwind-protect (progn ,@body) (flymake-mode -1))))
(ert-deftest nixi-untrusted-local-ordinary-backend-declined ()
  (nixi-with-local-file
   (should-not (trusted-content-p))
   (flymake-start nil t)
   (should (= 0 nixi-ordinary-calls))
   (should (memq 'nixi-ordinary-backend (flymake-disabled-backends)))))
(ert-deftest nixi-trusted-exact-file-positive ()
  (nixi-with-local-file
   (setq-local trusted-content (list (abbreviate-file-name buffer-file-truename)))
   (should (trusted-content-p))
   (flymake-start nil t)
   (should (= 1 nixi-ordinary-calls))
   (should-not (memq 'nixi-ordinary-backend (flymake-disabled-backends)))))
(ert-deftest nixi-explicit-untrusted-override-declined ()
  (nixi-with-local-file
   (setq-local trusted-content (list (abbreviate-file-name buffer-file-truename))
               untrusted-content t)
   (should-not (trusted-content-p))
   (flymake-start nil t)
   (should (= 0 nixi-ordinary-calls))
   (should (memq 'nixi-ordinary-backend (flymake-disabled-backends)))))
(ert-deftest nixi-declared-safe-marker-positive ()
  (nixi-with-local-file
   (setq-local flymake-diagnostic-functions '(nixi-safe-backend))
   (should-not (trusted-content-p))
   (flymake-start nil t)
   (should (= 1 nixi-safe-calls))
   (should-not (memq 'nixi-safe-backend (flymake-disabled-backends)))))
(ert-deftest nixi-mixed-backends-guarded-independently ()
  (nixi-with-local-file
   (setq-local flymake-diagnostic-functions '(nixi-ordinary-backend nixi-safe-backend))
   (flymake-start nil t)
   (should (= 0 nixi-ordinary-calls))
   (should (= 1 nixi-safe-calls))
   (should (memq 'nixi-ordinary-backend (flymake-disabled-backends)))
   (should-not (memq 'nixi-safe-backend (flymake-disabled-backends)))))
(ert-deftest nixi-force-reenable-does-not-bypass-trust ()
  (nixi-with-local-file
   (flymake-start nil t) (flymake-start nil t)
   (should (= 0 nixi-ordinary-calls))
   (should (memq 'nixi-ordinary-backend (flymake-disabled-backends)))))
(ert-deftest nixi-explicit-trust-restoration-and-reenable-positive ()
  (nixi-with-local-file
   (flymake-start nil t)
   (should (= 0 nixi-ordinary-calls))
   (setq-local trusted-content (list (abbreviate-file-name buffer-file-truename)))
   (flymake-start nil t)
   (should (= 1 nixi-ordinary-calls))
   (should-not (memq 'nixi-ordinary-backend (flymake-disabled-backends)))))
(ert-deftest nixi-zero-launch-attempts () (should-not nixi-launches))
(ert-run-tests-batch-and-exit)
