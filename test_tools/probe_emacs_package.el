;;; probe_emacs_package.el --- Opt-in native Darwin package smoke -*- lexical-binding: t; -*-
;; Emacs --batch --quick --no-site-file --load THIS GRAMMAR-LIB-DIR
;;   FRESH-SYNTHETIC-PROJECT PINNED-PYTHON STDIO-FIXTURE-SCRIPT [COLUMN [MODE]]
;; Default COLUMN=1 and MODE=recover give the scoped passing smoke. Explicit
;; COLUMN=0 reproduces an upstream initial-column diagnostic-loss edge; MODE
;; untrusted reproduces disabled-backend disconnect failure. Those opt-in
;; controls are expected to fail and are not accepted workflow behavior.
;; Arguments must be absolute local paths. Supply a fresh synthetic HOME too.
;; The stdio script is fixture_emacs_lsp.py from this directory. No real
;; language server, network, private Doom configuration or notes are used.
;; This covers actual compiled package libraries, JSON parsing, three more
;; grammar loads and Eglot/Flymake's file-trust boundary. It is not default CI.
(setq native-comp-jit-compilation nil
      native-comp-enable-subr-trampolines nil
      enable-local-variables nil enable-local-eval nil
      create-lockfiles nil make-backup-files nil
      vc-handled-backends nil
      project-find-functions nil)
(require 'ert)
(require 'cl-lib)
(require 'treesit)
(require 'eglot)
(defvar nixi-grammar-dir (pop command-line-args-left))
(defvar nixi-workflow-root (pop command-line-args-left))
(defvar nixi-python (pop command-line-args-left))
(defvar nixi-lsp-source (pop command-line-args-left))
(defvar nixi-diagnostic-column (or (pop command-line-args-left) "1"))
(defvar nixi-disconnect-mode (or (pop command-line-args-left) "recover"))
(unless (and (member nixi-diagnostic-column '("0" "1"))
             (member nixi-disconnect-mode '("recover" "untrusted")))
  (error "Synthetic controls require COLUMN 0/1 and MODE recover/untrusted"))
(dolist (path (list nixi-grammar-dir nixi-workflow-root nixi-python nixi-lsp-source))
  (unless (and (file-name-absolute-p path) (not (file-remote-p path)))
    (error "Explicit absolute local fixture paths are required")))
(defvar nixi-launch-count 0)
(defvar nixi-network-attempts 0)
(defun nixi-forbid-network (&rest _)
  (cl-incf nixi-network-attempts)
  (error "Network creation forbidden in workflow fixture"))
(advice-add 'make-network-process :override #'nixi-forbid-network)
(setq treesit-extra-load-path (list nixi-grammar-dir))
(defun nixi-diagnostic-request-count (log)
  (with-temp-buffer
    (insert-file-contents log)
    (how-many "^textDocument/diagnostic$" (point-min) (point-max))))
(defun nixi-await (predicate &optional seconds)
  (let ((until (+ (float-time) (or seconds 5))))
    (while (and (not (funcall predicate)) (< (float-time) until))
      (accept-process-output nil 0.05))
    (should (funcall predicate))))
(ert-deftest nixi-package-native-capabilities ()
  (should (string-prefix-p "31.1" emacs-version))
  (should (eq system-type 'darwin))
  (should (featurep 'ns))
  (should (native-comp-available-p))
  (should (treesit-available-p))
  (should (string-prefix-p "/nix/store/" (locate-library "eglot")))
  (should (string-prefix-p "/nix/store/" (locate-library "flymake"))))
(ert-deftest nixi-package-json-grammar-loads-and-parses ()
  (should (treesit-language-available-p 'json))
  (with-temp-buffer
    (insert "{\"fixture\": [1, true]}")
    (let* ((parser (treesit-parser-create 'json))
           (root (treesit-parser-root-node parser)))
      (should (equal (treesit-node-type root) "document"))
      (should-not (treesit-node-check root 'has-error))
      (should (equal (treesit-node-type (treesit-node-child root 0 t)) "object")))))
(ert-deftest nixi-package-other-core-grammars-load ()
  (dolist (language '(bash nix yaml))
    (should (treesit-language-available-p language))))
(ert-deftest nixi-package-eglot-trust-boundary-and-recovery ()
  (let* ((file (make-temp-file (expand-file-name "fixture-" nixi-workflow-root) nil ".txt"))
         (log (make-temp-file (expand-file-name "lsp-methods-" nixi-workflow-root) nil ".log"))
         (command (list nixi-python "-I" nixi-lsp-source log nixi-diagnostic-column))
         (original-make-process (symbol-function 'make-process))
         (eglot-sync-connect 5)
         (eglot-connect-timeout 5)
         (eglot-autoshutdown t)
         (eglot-events-buffer-config '(:size 0 :format full))
         buffer server)
    (with-temp-file file (insert "fixture text\n"))
    (unwind-protect
        (cl-letf (((symbol-function 'make-process)
                   (lambda (&rest args)
                     (should (equal (plist-get args :command) command))
                     (cl-incf nixi-launch-count)
                     (apply original-make-process args))))
          (setq buffer (find-file-noselect file))
          (with-current-buffer buffer
            (text-mode)
            (setq-local trusted-content nil)
            (setq-local flymake-no-changes-timeout nil)
            (should-not (trusted-content-p))
            (eglot '(text-mode) (cons 'transient nixi-workflow-root)
                   'eglot-lsp-server command '("plaintext"))
            (nixi-await (lambda () (eglot-managed-p)))
            (setq server (eglot-current-server))
            (should (jsonrpc-running-p server))
            (flymake-start nil t)
            (nixi-await (lambda () (memq 'eglot-flymake-backend
                                        (flymake-disabled-backends))))
            (should-not (flymake-diagnostics))
            (should-not (with-temp-buffer
                          (insert-file-contents log)
                          (search-forward "textDocument/diagnostic" nil t)))
            (setq-local trusted-content (list (abbreviate-file-name (file-truename file))))
            (should (trusted-content-p))
            (flymake-start nil t)
            (nixi-await (lambda () (flymake-diagnostics)))
            (should (string-match-p "synthetic diagnostic"
                                    (format "%s" (flymake-diagnostic-text (car (flymake-diagnostics))))))
            (should (memq 'eglot-flymake-backend (flymake-running-backends)))
            (let ((requests (nixi-diagnostic-request-count log)))
              (should (> requests 0))
              (setq-local untrusted-content t)
              (should-not (trusted-content-p))
              (flymake-start nil t)
              (nixi-await (lambda () (memq 'eglot-flymake-backend
                                          (flymake-disabled-backends))))
              (should (= requests (nixi-diagnostic-request-count log))))
            ;; Restore the exact synthetic file's trust before teardown.
            ;; Upstream Eglot can retain a stale callback when a running
            ;; Flymake backend is disabled; untrusted disconnect is not
            ;; accepted by this scoped smoke test.
            (unless (equal nixi-disconnect-mode "untrusted")
              (setq-local untrusted-content nil)
              (flymake-start nil t)
              (nixi-await (lambda () (memq 'eglot-flymake-backend
                                          (flymake-reporting-backends))))
              (should (flymake-diagnostics)))
            (eglot-shutdown server nil 2)
            (setq server nil)
            (should (= nixi-launch-count 1))
            (should (= nixi-network-attempts 0))))
      (when (and server (jsonrpc-running-p server))
        (ignore-errors (eglot-shutdown server nil 1)))
      (when (buffer-live-p buffer) (kill-buffer buffer)))
    (let ((methods (with-temp-buffer (insert-file-contents log) (buffer-string))))
      (dolist (method '("initialize" "textDocument/didOpen" "shutdown" "exit"))
        (should (string-match-p (concat "^" (regexp-quote method) "$") methods))))))
(ert-run-tests-batch-and-exit)
