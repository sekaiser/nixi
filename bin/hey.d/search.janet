#!/usr/bin/env janet
# Search Nix packages from the command line.
#
# SYNOPSIS:
#   hey search [--json] [--from INSTALLABLE] QUERY...
#
# EXAMPLES:
#   hey search ripgrep
#   hey search rust analyzer
#   hey search --from nixpkgs#gnome3 vala
#   hey search --json process-compose

(use hey)
(use hey/cmd)

(def- usage
  "Usage: hey search [--json] [--from INSTALLABLE] QUERY...")

(defn- search-packages [queries installable json?]
  (when (empty? queries)
    (abort usage))
  (let [cmd @["nix" "search" "--no-write-lock-file"]]
    (when json?
      (array/push cmd "--json"))
    (array/push cmd (or installable "nixpkgs"))
    (array/concat cmd queries)
    (if (dryrun?)
      (echof "DRYRUN: %s" (string/join cmd " "))
      (let [status (execute-clean cmd)]
        (unless (= 0 status)
          (exit status))))))

(defcmd search [_ & queries &opts installable ["--from" installable] json? --json]
  (search-packages queries installable json?))
