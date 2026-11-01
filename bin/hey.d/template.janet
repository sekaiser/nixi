#!/usr/bin/env janet
# Initialize local project templates without evaluating the flake.
#
# SYNOPSIS:
#   template list
#   template init NAME [DIR]
#
# SUBCOMMANDS:
#   list  List available templates.
#   init  Copy a template into DIR, or the current directory if DIR is omitted.

(use hey)
(use hey/cmd)

(def- usage
  "Usage: hey template list | hey template init NAME [DIR]")

(defn- templates-dir []
  (path :framework "templates"))

(defn- template-path [name]
  (path/join (templates-dir) name))

(defn- template-source [name]
  (let [root (os/realpath (templates-dir))
        source (ignore-errors (os/realpath (template-path name)))]
    (when (and source
               (path/directory? source)
               (string/has-prefix? (string root "/") source))
      source)))

(defn- template-names []
  (sort
    (filter template-source
            (os/dir (templates-dir)))))

(defn- list-templates []
  (each name (template-names)
    (echo name)))

(defn- empty-dir? [dir]
  (or (not (path/exists? dir))
      (and (path/directory? dir)
           (empty? (os/dir dir)))))

(defn- init-template [name target]
  (unless (index-of name (template-names))
    (abort "Unknown template: %s" name))
  (let [source (template-source name)
        dest (path/abspath (or target "."))]
    (unless source
      (abort "Unknown template: %s" name))
    (unless (empty-dir? dest)
      (abort "Target directory is not empty: %s" dest))
    (if (dryrun?)
      (do
        (echof "DRYRUN: mkdir -p %s" dest)
        (echof "DRYRUN: rsync -a --chmod=u+w -- %s/ %s/" source dest))
      (do
        (path/mkdirp dest)
        # Store sources are read-only; generated projects must be editable.
        (unless (= 0 (execute-clean @["rsync" "-a" "--chmod=u+w" "--" (string source "/") (string dest "/")]))
          (exit 1))))
    (echof :check "template %s initialized in %s" name dest)))

(defcmd template [_ subcmd name & args]
  (case* subcmd
    "list" (if (and (nil? name) (empty? args))
             (list-templates)
             (abort usage))
    "init" (if (and name (<= (length args) 1))
             (init-template name (get args 0))
             (abort usage))
    nil (abort usage)
    (abort usage)))
