#!/usr/bin/env janet
# Remove known local runtime caches.
#
# SYNOPSIS:
#   clean [all|zsh|nix|k9s|cache]
#
# SUBCOMMANDS:
#   all    Remove all supported local caches.
#   zsh    Remove zsh and zgenom caches.
#   nix    Remove local hey Nix scratch state.
#   k9s    Remove k9s screen/cache state.
#   cache  Remove hey cache state.

(use hey)
(use hey/cmd)

(defn- zsh-targets []
  @[(path/xdg :cache "zsh")
    (path/xdg :data "zgenom" "init.zsh")
    (path/xdg :data "zgenom" "zcompdump")
    (path/xdg :config "zsh" ".zcompdump")
    (path/xdg :config "zsh" ".zcompdump.zwc")])

(defn- nix-targets []
  @[(path :runtime "profile.diff.a")
    (path :runtime "profile.diff.b")])

(defn- k9s-targets []
  @[(path/xdg :state "k9s" "screen-dumps")
    (path/xdg :cache "k9s")])

(defn- cache-targets []
  @[(path :cache)])

(defn- targets [target]
  (case target
    "zsh" (zsh-targets)
    "nix" (nix-targets)
    "k9s" (k9s-targets)
    "cache" (cache-targets)
    "all" [;(zsh-targets) ;(nix-targets) ;(k9s-targets) ;(cache-targets)]
    (abort "Usage: hey clean [all|zsh|nix|k9s|cache]")))

(defn- remove-target [target]
  (if (dryrun?)
    (echof "DRYRUN: rm -rf %s" target)
    (when (path/exists? target)
      (path/rmtree target)
      (echof :check "removed %s" target))))

(defcmd clean [_ target & args]
  (unless (empty? args)
    (abort "Usage: hey clean [all|zsh|nix|k9s|cache]"))
  (each target (targets (or target "all"))
    (remove-target target))
  (echo :check "clean complete"))
