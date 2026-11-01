#!/usr/bin/env janet

(use judge)
(use hey)
(import hey/glob)

(deftest to-peg
  (test (truthy? (peg/match (glob/to-peg "flake.nix") "flake.nix")) true)
  (test (truthy? (peg/match (glob/to-peg "flake.nix") "flake.lock")) false)
  (test-error (glob/to-peg "**") "** not supported")
  (test-error (glob/to-peg "***") "invalid glob pattern"))

(deftest match*
  (test (glob/match* "flake.nix" "flake.nix") true)
  (test (glob/match* "flake.nix" "flake.lock") false)
  (test (glob/match* "*.nix" "flake.nix") true)
  (test (glob/match* "*.nix" "flake.lock") false)
  (test (glob/match* "foo?" "foo1") true)
  (test (glob/match* "foo?" "foo") false))

(deftest match
  (test (glob/match "*.janet" "glob.janet") true)
  (test (glob/match "*.janet" "glob.nix") false))

(deftest case
  (test (glob/case "flake.nix"
          "*.janet" :janet
          "*.nix" :nix
          :other)
        :nix)
  (test (glob/case "README.md"
          "*.janet" :janet
          "*.nix" :nix
          :other)
        :other))
