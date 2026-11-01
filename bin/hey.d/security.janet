#!/usr/bin/env janet
# Run advisory scanning explicitly; never update, build or activate a host.
#
# SYNOPSIS:
#   hey security scan STORE_PATH [--json]
#
# Requires vulnix installed from your reviewed package snapshot. Downloads and
# caches advisory data; reports and scanner diagnostics may identify packages
# and store paths. Keep private-host reports local. No automatic suppressions.

(use hey)
(use hey/cmd)

(defcmd security [_ action target & args &opts json? --json]
  (unless (and (= action "scan") (empty? args) (string? target)
               (peg/match '(* "/nix/store/" (repeat 32 (set "0123456789abcdfghijklmnpqrsvwxyz"))
                              "-" (some (+ :w (set "+._?=-"))) -1) target))
    (abort "Usage: hey security scan /nix/store/HASH-NAME [--json]"))
  (let [argv @["vulnix" "--no-default-whitelist"]]
    (when json? (array/push argv "--json"))
    (array/push argv "--" target)
    (if (dryrun?)
      (echof "DRYRUN: %s" (string/join argv " "))
      (do
        (unless (path/find "vulnix")
          (abort "vulnix is not installed; select it from your reviewed Nixpkgs snapshot. Nothing was installed or scanned."))
        (eprintf "Advisory scan only; no deployment. Matching is heuristic, not proof of vulnerability or safety. Keep reports private.\n")
        (let [status (execute-clean argv)]
          (unless (= 0 status) (exit status)))))))
