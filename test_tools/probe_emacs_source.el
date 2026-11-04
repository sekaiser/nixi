;;; probe_emacs_source.el --- Bounded source-only security checks -*- lexical-binding: t; -*-
;; Run with Emacs 31.1 --batch --quick --load this-file SOURCE-TREE.
;; Pass --installed instead of SOURCE-TREE to test package compiled libraries.
;; SOURCE-TREE contains reviewed GNU source, optionally patched. Never open a
;; remote file or run a real diagnostic backend. Source mode does not qualify
;; an installed package or GUI; --installed accepts compiled libraries only.
;; The reviewed upstream candidate still fails expanded-user validation. Keep
;; that regression visible; do not mark it expected or treat this as clean CI.
(setq native-comp-jit-compilation nil
      native-comp-enable-subr-trampolines nil
      enable-local-variables nil
      enable-local-eval nil
      vc-handled-backends nil
      create-lockfiles nil)
(require 'ert)
(require 'cl-lib)
(defvar nixi-probe-launch-attempts nil)
(defun nixi-probe-forbid-launch (operation &rest _args)
  (push operation nixi-probe-launch-attempts)
  (error "Process/network operations are forbidden in this source probe"))
(dolist (fn '(make-process make-network-process call-process call-process-region
              process-file start-process start-file-process open-network-stream))
  (advice-add fn :override (apply-partially #'nixi-probe-forbid-launch fn)))
(defvar nixi-probe-source (pop command-line-args-left))
(if (equal nixi-probe-source "--installed")
    ;; Explicit package acceptance: use only the interpreter's normal compiled
    ;; libraries, without loading source trees or changing load-path.
    (progn
      (require 'tramp)
      (require 'tramp-archive)
      (require 'flymake)
      (require 'elisp-mode))
  (unless (and nixi-probe-source (file-name-absolute-p nixi-probe-source))
    (error "An absolute reviewed source tree or --installed mode is required"))
  (dolist (file '("lisp/net/tramp.el" "lisp/net/tramp-archive.el"
                  "lisp/progmodes/flymake.el" "lisp/progmodes/elisp-mode.el"))
    (load (expand-file-name file nixi-probe-source) nil t t)))
(defun nixi-probe-parse (user &optional host)
  (tramp-dissect-file-name
   (format "/ssh:%s@%s:/nixi-probe" user (or host "host.invalid")) t))
(ert-deftest nixi-source-ordinary-users ()
  (dolist (user '("review" "build-user" "build_user" "review.name"))
    (should (equal user (tramp-file-name-user (nixi-probe-parse user))))))
(ert-deftest nixi-source-forbidden-user-characters ()
  (dolist (char '(?! ?# ?& ?, 1 10 31))
    (should-error (nixi-probe-parse (concat "review" (string char) "name")))))
(ert-deftest nixi-source-ordinary-expanded-user ()
  (let ((process-environment (copy-sequence process-environment)))
    (setenv "NIXI_PROBE_USER" "review")
    (should (equal "review"
                   (tramp-file-name-user (nixi-probe-parse "$NIXI_PROBE_USER"))))))
(ert-deftest nixi-source-expanded-user-is-revalidated ()
  (let ((process-environment (copy-sequence process-environment)))
    (dolist (char '(?! ?# ?& ?, 1 10 31))
      (dolist (parts '(("" "review") ("review" "name") ("review" "")))
        (setenv "NIXI_PROBE_USER" (concat (car parts) (string char) (cadr parts)))
        (should-error (nixi-probe-parse "$NIXI_PROBE_USER"))))))
(ert-deftest nixi-source-expanded-user-normal-default-resolution ()
  ;; Register only the method name, without opening a connection. Exercise the
  ;; production default-resolution branch as well as NODEFAULT parsing above.
  (let ((process-environment (copy-sequence process-environment))
        (tramp-methods '(("ssh"))))
    (setenv "NIXI_PROBE_USER" "review!name")
    (should-error
     (tramp-dissect-file-name "/ssh:$NIXI_PROBE_USER@host.invalid:/nixi-probe"))))
(ert-deftest nixi-source-expanded-user-domain ()
  (let ((process-environment (copy-sequence process-environment)))
    (setenv "NIXI_PROBE_USER" "review%DOMAIN")
    (let ((vec (nixi-probe-parse "$NIXI_PROBE_USER")))
      (should (equal "review" (tramp-file-name-user vec)))
      (should (equal "DOMAIN" (tramp-file-name-domain vec))))))
(ert-deftest nixi-source-expanded-user-domain-does-not-discard-invalid-text ()
  (let ((process-environment (copy-sequence process-environment)))
    (dolist (user '("invalid!review%DOMAIN" "review%DOMAIN!invalid"))
      (setenv "NIXI_PROBE_USER" user)
      (should-error (nixi-probe-parse "$NIXI_PROBE_USER")))))
(ert-deftest nixi-source-default-user-policy ()
  (let ((tramp-methods '(("ssh")))
        (tramp-default-user-alist nil)
        (tramp-default-user "review"))
    (should (equal "review" (tramp-file-name-user
                             (tramp-dissect-file-name "/ssh:host.invalid:/nixi-probe"))))
    (setq tramp-default-user "review!name")
    (should-error (tramp-dissect-file-name "/ssh:host.invalid:/nixi-probe"))))
(ert-deftest nixi-source-ipv6-and-port-still-parse ()
  ;; Do not anchor tramp-host-regexp: IPv6 follows a separate host grammar.
  (let ((vec (nixi-probe-parse "review" "[2001:db8::1]#2222")))
    (should (equal "2001:db8::1" (tramp-file-name-host vec)))
    (should (equal "2222" (tramp-file-name-port vec)))))
(ert-deftest nixi-source-expanded-user-percent-policy ()
  (let ((process-environment (copy-sequence process-environment)))
    (setenv "NIXI_PROBE_USER" "review%DOMAIN%")
    (let ((tramp-allow-double-percent nil))
      (should-error (nixi-probe-parse "$NIXI_PROBE_USER")))
    (let ((tramp-allow-double-percent t))
      (should (equal "review%DOMAIN%"
                     (tramp-file-name-user (nixi-probe-parse "$NIXI_PROBE_USER")))))))
(ert-deftest nixi-source-percent-policy ()
  (let ((tramp-allow-double-percent nil))
    (should-error (nixi-probe-parse "review" "host%DOMAIN%")))
  (let ((tramp-allow-double-percent t))
    (should (nixi-probe-parse "review" "host%DOMAIN%"))))
(ert-deftest nixi-source-archive-percent-profile ()
  (let (connection-local-variables-alist)
    (hack-connection-local-variables '(:application tramp :protocol "archive"))
    (should (eq t (alist-get 'tramp-allow-double-percent
                             connection-local-variables-alist)))))
(defvar nixi-probe-backend-calls 0)
(defun nixi-probe-backend (_report &rest _args)
  (cl-incf nixi-probe-backend-calls))
(defun nixi-probe-run-backend (trusted safe)
  (with-temp-buffer
    (let ((nixi-probe-backend-calls 0)
          (flymake-diagnostic-functions '(nixi-probe-backend))
          (flymake--state (make-hash-table :test #'eq)))
      (unwind-protect
          (cl-letf (((symbol-function 'trusted-content-p) (lambda (&rest _) trusted)))
            (function-put #'nixi-probe-backend 'flymake-always-safe safe)
            (flymake--run-backend #'nixi-probe-backend)
            (list nixi-probe-backend-calls
                  (and (memq #'nixi-probe-backend (flymake-disabled-backends)) t)))
        (function-put #'nixi-probe-backend 'flymake-always-safe nil)))))
(ert-deftest nixi-source-untrusted-backend-is-disabled ()
  (should (equal '(0 t) (nixi-probe-run-backend nil nil))))
(ert-deftest nixi-source-trusted-backend-still-runs ()
  (should (equal '(1 nil) (nixi-probe-run-backend t nil))))
(ert-deftest nixi-source-explicitly-safe-backend-still-runs ()
  (should (equal '(1 nil) (nixi-probe-run-backend nil t))))
(ert-deftest nixi-source-original-elisp-guard-remains ()
  (with-temp-buffer
    (cl-letf (((symbol-function 'trusted-content-p) (lambda (&rest _) nil)))
      (should-error (elisp-flymake-byte-compile #'ignore) :type 'user-error))))
(ert-deftest nixi-source-zero-process-or-network-attempts ()
  (should-not nixi-probe-launch-attempts))
(ert-run-tests-batch-and-exit "^nixi-source-")
