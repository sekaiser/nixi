#!/usr/bin/env janet
# Garbage collect and optimize the nix store.
#
# SYNOPSIS:
#   gc [-a|--all] [-s|--system] [-d]
#
# OPTIONS:
#   -a, --all
#     GC both the user and system profiles.
#   -s, --system
#     Only prune the system profile. Store garbage collection is always global.
#   -d
#     Delete old profiles as well.

(use hey)
(use hey/cmd)
(import hey/process)
(import hey/system)

(def- run-command process/run!)

(defcmd gc [_ & args &opts
            all? [-a --all]
            system? [-s --system]
            delete-old? -d]
  (unless (empty? args)
    (abort "Usage: hey gc [-a|--all] [-s|--system] [-d]"))
  # Never use nix-collect-garbage -d: it discovers profiles outside the
  # requested scope, especially when run as root. Prune explicit profiles
  # first, refresh boot roots, then collect the store once.
  (when delete-old?
    (os/with-lock (path :runtime "profile-rm.lock")
      (when (or all? system?)
        (echo :g "> Pruning old system generations...")
        (system/delete-generations (path :profile) ["old"] false))
      (when (or all? (not system?))
        (echo :g "> Pruning old user generations...")
        (system/delete-generations (path :profile*) ["old"] true))))

  (echo :g "> Collecting unreachable store paths...")
  (run-command (if (or all? system?) @["sudo" "nix-store" "--gc"] @["nix-store" "--gc"]))
  (when (or all? system?)
    (echo :g "> Optimizing the nix store...")
    (run-command @["nix-store" "--optimise"]))

  (echo :check "Done!"))
