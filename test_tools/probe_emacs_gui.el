;;; probe_emacs_gui.el --- Opt-in isolated Cocoa receipt -*- lexical-binding: t; -*-
;; Launch a NEW background Emacs.app with synthetic HOME and --quick
;; --no-site-file --load THIS GRAMMAR-LIB-DIR FRESH-RECEIPT.
;; The caller must use an isolated new process, never an existing editor.
;; This creates a hidden native frame, parses synthetic JSON, writes a receipt
;; and exits. It does not establish Finder registration or Doom acceptance.
(setq enable-local-variables nil enable-local-eval nil
      native-comp-jit-compilation nil native-comp-enable-subr-trampolines nil
      create-lockfiles nil make-backup-files nil)
(run-at-time 30 nil (lambda () (kill-emacs 3)))
(require 'json)
(require 'treesit)
(defvar nixi-gui-grammars (pop command-line-args-left))
(defvar nixi-gui-receipt (pop command-line-args-left))
(unless (and (stringp nixi-gui-grammars) (stringp nixi-gui-receipt)
             (file-name-absolute-p nixi-gui-grammars)
             (file-name-absolute-p nixi-gui-receipt)
             (not (file-remote-p nixi-gui-grammars))
             (not (file-remote-p nixi-gui-receipt))
             (not (file-exists-p nixi-gui-receipt)))
  (kill-emacs 2))
(defun nixi-gui-forbid-launch (&rest _)
  (error "Process/network launch forbidden in GUI receipt fixture"))
(dolist (fn '(make-process make-network-process call-process call-process-region
              process-file start-process start-file-process open-network-stream))
  (advice-add fn :override #'nixi-gui-forbid-launch))
(let ((status 0) frame)
  (unwind-protect
      (condition-case err
          (progn
            (setq treesit-extra-load-path (list nixi-gui-grammars))
            (setq frame (make-frame '((name . "Nixi isolated package acceptance")
                                     (visibility . nil) (width . 40) (height . 10))))
            (unless (and (eq (window-system frame) 'ns) (display-graphic-p frame))
              (error "A native Cocoa graphic frame is required"))
            (unless (treesit-language-available-p 'json) (error "JSON grammar unavailable"))
            (with-temp-buffer
              (insert "{\"fixture\": true}")
              (let ((node (treesit-parser-root-node (treesit-parser-create 'json))))
                (when (treesit-node-check node 'has-error) (error "JSON parse failed"))))
            (with-temp-file nixi-gui-receipt
              (insert (json-encode `((status . "passed") (version . ,emacs-version)
                                     (windowSystem . "ns") (graphic . t)
                                     (jsonGrammar . t) (privateConfig . :json-false))))))
        (error
         (setq status 1)
         (with-temp-file nixi-gui-receipt
           (insert (json-encode `((status . "failed") (error . ,(error-message-string err))))))))
    (when (frame-live-p frame) (delete-frame frame t))
    (kill-emacs status)))
