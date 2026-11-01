#!/usr/bin/env janet

(use judge)
(use hey)
(use hey/nix)

(deftest flake-ref
  (test (nix/flake-ref ".#laptop" "/dotfiles") "/dotfiles")
  (test (nix/flake-ref "/tmp/site#vm-a" "/dotfiles") "/tmp/site")
  (test (nix/flake-host "/tmp/site#vm-a") "vm-a"))

(deftest eval-argvs-do-not-write-lock-files
  (test (nix/eval-json-argv "/tmp/site#checks.aarch64-linux" "builtins.attrNames")
        @["nix" "eval" "--impure" "--json" "--no-write-lock-file"
          "/tmp/site#checks.aarch64-linux" "--apply" "builtins.attrNames"])
  (test (nix/eval-raw-argv "/tmp/site#nixosConfigurations.vm.config.system.build.toplevel.drvPath")
        @["nix" "eval" "--impure" "--raw" "--no-write-lock-file"
          "/tmp/site#nixosConfigurations.vm.config.system.build.toplevel.drvPath"]))

(deftest host-targets
  (test (nix/darwin-system-drv-path-target "/tmp/site" "laptop")
        "/tmp/site#darwinConfigurations.laptop.system.drvPath")
  (test (nix/nixos-toplevel-drv-path-target "/tmp/site" "vm-a")
        "/tmp/site#nixosConfigurations.vm-a.config.system.build.toplevel.drvPath")
  (test (nix/nixos-image-target "/tmp/site" "vm-a")
        "/tmp/site#nixosConfigurations.vm-a.config.system.build.images.qemu-efi"))

(deftest quoted-attribute-targets
  (test (nix/darwin-system-drv-path-target "/tmp/site" "node.example")
        "/tmp/site#darwinConfigurations.\"node.example\".system.drvPath")
  (test (nix/nixos-toplevel-target "/tmp/site" "node.example")
        "/tmp/site#nixosConfigurations.\"node.example\".config.system.build.toplevel")
  (test (nix/nixos-iso-target "/tmp/site" "node.example")
        "/tmp/site#nixosConfigurations.\"node.example\".config.system.build.isoImage")
  (test (nix/nixos-image-drv-path-target "/tmp/site" "node.example" "image.v2")
        "/tmp/site#nixosConfigurations.\"node.example\".config.system.build.images.\"image.v2\".drvPath")
  (test (nix/flake-check-target "/tmp/site" "aarch64-linux" "check name")
        "/tmp/site#checks.aarch64-linux.\"check name\"")
  (test (nix/flake-target "/tmp/site" "a\\b") "/tmp/site#\"a\\b\"")
  (test (nix/flake-target "/tmp/site" "laptop'" "123") "/tmp/site#laptop'.\"123\"")
  (test (first (protect (nix/flake-target "/tmp/site" "a\"b"))) false)
  (test (first (protect (nix/flake-target "/tmp/site" ""))) false))
