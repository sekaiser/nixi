#!/usr/bin/env janet
# Show the currently inferred hey/Nix context.
#
# SYNOPSIS:
#   context
#
# SUBCOMMANDS:
#   context  Print host, user, flake, shell, Nix, and Kubernetes context.

(use hey)
(use hey/cmd)
(import hey/process)

(defn- run [args]
  (ignore-errors
    (string/trim (process/output args 10))))

(defn- field [label value]
  (echof "%-18s %s" label (or value "<unset>")))

(defcmd context [_ & args]
  (unless (empty? args)
    (abort "Usage: hey context"))
  (let [system (run @["uname"])
        hostname (run @["hostname" "-s"])
        nix-version (run @["nix" "--version"])
        kube-context (run @["kubectl" "config" "current-context"])]
    (field "host" (flake :host))
    (field "hostname" hostname)
    (field "user" (flake :user))
    (field "system" system)
    (field "flake" (string (flake :path) "#" (flake :host)))
    (field "theme" (flake :theme))
    (field "DOTFILES" (or (os/getenv "DOTFILES") (flake :path)))
    (field "DOTFILES_HOME" (or (os/getenv "DOTFILES_HOME") (flake :path)))
    (field "NIX_CONFIG" (if (os/getenv "NIX_CONFIG") "<set; contents hidden>" "<unset>"))
    (field "shell" (os/getenv "SHELL"))
    (field "nix" nix-version)
    (field "kube context" kube-context)))
