#!/usr/bin/env janet
# Open a nix or janet repl with this flake preloaded.
#
# SYNOPSIS:
#   repl [-j|-d] [ARGS...]
#
# OPTIONS:
#   -j
#     Start a Janet REPL instead.
#   -d
#     Start nix develop instead.
#

(use hey)
(use hey/cmd)

(defn- setenv-when [name value]
  (when value
    (os/setenv name value)))

(defn- run-repl [args]
  (if (dryrun?)
    (echof "DRYRUN: %s" (string/join args " "))
    (let [status (execute-clean args)]
      (unless (= 0 status)
        (exit status)))))

(defcmd repl [_ & args &opts
              janet? -j
              nixdev? -d]
  (when (and janet? nixdev?)
    (abort "Usage: hey repl [-j|-d] [ARGS...]"))
  (setenv-when "DOTFILES" (flake :path))
  (setenv-when "HEY_USER" (flake :user))
  (cond janet?
        (do (echo :g "Starting Janet REPL (w/ HeyLib preloaded)...")
            (run-repl @["janet"
                        "-l" "hey"
                        "-l" "hey/cmd"
                        "-e" "(import hey/vars)"
                        "-e" "(import hey/glob)"
                        "-e" "(import hey/sys)"
                        "-p" "-r"
                        ;args]))

        nixdev?
        (do (echo :g "Starting nix-develop REPL (w/ flake preloaded)...")
            (run-repl @["nix" "develop" (path :home) ;args]))

        (do (echo :g "Starting nix REPL (w/ flake preloaded)...")
            (run-repl @["nix" "repl"
                        "--extra-experimental-features" "flakes repl-flake"
                        "--impure"
                        (path :home)
                        ;args]))))
