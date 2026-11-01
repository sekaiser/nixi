#!/usr/bin/env janet
# Validate flake hosts at different cost levels.
#
# SYNOPSIS:
#   check eval [HOST] [--flake FLAKE]
#   check build HOST [--flake FLAKE]
#   check image HOST [--flake FLAKE]
#   check flake [--flake FLAKE]
#   check framework
#   check unit
#   check cli
#   check utm-cli
#   check all [HOST]
#
# SUBCOMMANDS:
#   eval        Check flake outputs and evaluate all host system derivations.
#   build HOST  Build one host system closure.
#   image HOST  Build one host qemu-efi image.
#   flake       Build flake checks for the current system.
#   framework   Validate Nixi's own exported module and check contract.
#   unit        Run the Janet/Judge unit tests.
#   cli         Validate generic hey dry-run command wiring.
#   utm-cli     Validate UTM CLI dry-run command wiring.
#   all         Validate the consumer's checks and host derivations.

(use hey)
(use hey/nix)
(use hey/cmd)

(def- usage
  "Usage: hey check [--flake FLAKE] eval [HOST] | hey check [--flake FLAKE] build HOST | hey check [--flake FLAKE] image HOST | hey check [--flake FLAKE] flake | hey check framework | hey check unit | hey check cli | hey check utm-cli | hey check all [HOST]")

(defn- eval-host [flake-ref kind host]
  (let [target (nix/host-eval-target flake-ref kind host)
        [ok result] (protect (nix/eval-raw target))]
    (if ok
      (do
        (echof :check "%s %s" kind host)
        true)
      (do
        (echof :error "%s %s failed" kind host)
        (echo :err result)
        false))))

(defn- build-host [flake-ref host]
  (if (dryrun?)
    (do
      (echof "DRYRUN: inspect host kind in %s without building" flake-ref)
      (echof "DRYRUN: Darwin target: %s" (nix/darwin-system-target flake-ref host))
      (echof "DRYRUN: NixOS target: %s" (nix/nixos-toplevel-target flake-ref host)))
    (let [kind (nix/host-kind flake-ref host)]
      (unless kind
        (abort "Unknown host: %s" host))
      (nix/build "--impure" (nix/host-build-target flake-ref kind host)))))

(defn- build-image [flake-ref host]
  (unless (index-of host (nix/nixos-hosts flake-ref))
    (abort "Unknown NixOS host: %s" host))
  (let [target (nix/nixos-image-target flake-ref host)]
    (if (dryrun?)
      (echof "DRYRUN: %s" (string/join (nix/build-argv "--impure" target) " "))
      (do
        (let [[ok result] (protect (nix/eval-raw
                                      (nix/nixos-image-drv-path-target flake-ref host)))]
          (unless ok
            (echo :err result)
            (abort "Host %s does not have an evaluable qemu-efi image target" host)))
        (nix/build "--impure" target)))))

(defn- check-name-set [label names required]
  (let [missing (filter |(not (index-of $ names)) required)]
    (if (empty? missing)
      (do
        (echof :check "%s" label)
        true)
      (do
        (echof :error "%s missing: %s" label (string/join missing ", "))
        false))))

(defn- local-check-names [system]
  # Read definition metadata without evaluating derivations. Linux-only boot
  # tests must not be required in Darwin's exported check set.
  (json/decode
    (nix/eval-raw "--file" (path :framework "runtime/hey/check-definitions.nix") "result"
      "--argstr" "directory" (path :framework "checks")
      "--argstr" "system" system)))

(defn- check-flake-contract [flake-ref]
  (var ok true)
  # Host inventory belongs to the consumer. eval-all evaluates only declared
  # hosts; standalone Nixi intentionally exports no personal configurations.
  (unless (check-name-set
            "mkFlake darwin modules"
            (nix/flake-output-names flake-ref "darwinModules")
            @["default"])
    (set ok false))
  (unless (check-name-set
            "mkFlake nixos modules"
            (nix/flake-output-names flake-ref "nixosModules")
            @["default"])
    (set ok false))
  (unless (check-name-set
            "mkFlake current-system checks"
            (nix/flake-check-names flake-ref (nix/current-system))
            (local-check-names (nix/current-system)))
    (set ok false))
  ok)

(defn- eval-all [flake-ref]
  (var ok true)
  (each host (nix/darwin-hosts flake-ref)
    (unless (eval-host flake-ref :darwin host)
      (set ok false)))
  (each host (nix/nixos-hosts flake-ref)
    (unless (eval-host flake-ref :nixos host)
      (set ok false)))
  (unless ok
    (exit 1)))

(defn- eval-one [flake-ref host]
  (if (dryrun?)
    (do
      (echof "DRYRUN: inspect host kind in %s without evaluating" flake-ref)
      (echof "DRYRUN: Darwin eval target: %s" (nix/darwin-system-drv-path-target flake-ref host))
      (echof "DRYRUN: NixOS eval target: %s" (nix/nixos-toplevel-drv-path-target flake-ref host)))
    (let [kind (nix/host-kind flake-ref host)]
      (unless kind
        (abort "Unknown host: %s" host))
      (unless (eval-host flake-ref kind host)
        (exit 1)))))

(defn- check-flake [flake-ref]
  (if (dryrun?)
    (echof "DRYRUN: build all flake checks for the current system from %s" flake-ref)
    (let [system (nix/current-system)
          checks (nix/flake-check-names flake-ref system)]
      (each check checks
        (nix/build "--impure" "--no-link" (nix/flake-check-target flake-ref system check))
        (echof :check "flake %s.%s" system check)))))

(defn- run-test-suite [name]
  (if (dryrun?)
    (echof "DRYRUN: run %s test suite" name)
    (let [suite (require (string "@" (path :framework "test/cli" name)))]
      ((get-in suite ['run :value])))))

(defcmd check [_ subcmd & args
               &opts flake-opt ["--flake" flake-opt]]
  (let [flake-ref (or flake-opt (path :home))]
  (case* subcmd
    "eval" (if (<= (length args) 1)
             (if-let [host (first args)]
               (eval-one flake-ref host)
               (eval-all flake-ref))
             (abort usage))
    "build" (if (= (length args) 1)
              (let [host (first args)]
                (build-host flake-ref host))
              (abort "Usage: hey check build HOST"))
    "image" (if (= (length args) 1)
              (let [host (first args)]
                (build-image flake-ref host))
              (abort "Usage: hey check image HOST"))
    "flake" (if (empty? args)
              (check-flake flake-ref)
              (abort usage))
    "unit" (if (empty? args)
             (run-test-suite "unit")
             (abort usage))
    "framework" (if (empty? args)
                  (unless (check-flake-contract (path :framework)) (exit 1))
                  (abort usage))
    "cli" (if (empty? args)
            (run-test-suite "generic")
            (abort usage))
    "utm-cli" (if (empty? args)
                (run-test-suite "utm")
                (abort usage))
    "all" (if (<= (length args) 1)
            (do
              (check-flake flake-ref)
              (if-let [host (first args)]
                (eval-one flake-ref host)
                (eval-all flake-ref)))
            (abort usage))
    (abort usage))))
