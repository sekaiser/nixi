;;; config.el -*- lexical-binding: t; -*-

(setq doom-theme 'doom-one
      display-line-numbers-type 'relative
      org-directory (expand-file-name "~/org"))

;; Mac port uses mac-*; NS/Cocoa alternatives use ns-*.
;; Keep Option available for international keyboard characters.
(when IS-MAC
  (setq mac-command-modifier 'meta
        mac-option-modifier 'none
        ns-command-modifier 'meta
        ns-option-modifier 'none))

;; Linux keeps its normal Alt/Meta bindings and PGTK desktop integration.
