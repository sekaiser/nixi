;;; init.el -*- lexical-binding: t; -*-

(doom! :completion
       company
       ivy
       (vertico +icons)

       :ui
       doom
       dashboard
       (modeline +light)
       ophints
       (popup +defaults)
       vc-gutter
       workspaces
       hl-todo
       treemacs
       unicode
       vi-tilde-fringe
       window-select

       :editor
       (evil +everywhere)
       file-templates
       fold
       (format +onsave)
       multiple-cursors
       rotate-text
       snippets

       :emacs
       dired
       electric
       undo
       vc

       :term
       vterm

       :tools
       docker
       editorconfig
       eval
       lookup
       magit
       tree-sitter

       :os
       (:if IS-MAC macos)

       :lang
       data
       emacs-lisp
       json
       markdown
       nix
       (org              ; organize your plain life in plain text
        +roam2
        +dragndrop
        +hugo
        +journal
        +noter
        +pandoc
        +pomodoro
        +pretty
        +present
        +attach          ; custom attachment system
        +babel           ; running code in org
        +capture         ; org-capture in and outside of Emacs
        +export          ; Exporting org to whatever you want
        +present         ; Emacs for presentations
        +protocol)       ; Support for org-protocol:// links
       plantuml
       (sh +zsh)
       yaml

       :config
       (default +bindings +smartparens))
