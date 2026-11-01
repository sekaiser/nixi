#!/usr/bin/env janet
# Build NixOS VM images from host configurations.
#
# SYNOPSIS:
#   image list HOST [--flake FLAKE]
#   image build HOST [VARIANT] [--flake FLAKE]
#
# SUBCOMMANDS:
#   list        List image-like system.build attributes for HOST.
#   build       Build HOST image variant. Defaults to qemu-efi.

(use hey)
(use hey/nix)
(use hey/cmd)

(def- usage
  "Usage: hey image list HOST [--flake FLAKE] | hey image build HOST [VARIANT] [--flake FLAKE]")

(defn- normalize-variant [variant]
  (let [variant (or variant "qemu-efi")]
    (if (= variant "qcow-efi")
      "qemu-efi"
      variant)))

(defn- list-images [flake-ref host]
  (if (dryrun?)
    (echof "DRYRUN: nix eval --impure --json --no-write-lock-file %s --apply builtins.attrNames"
           (nix/nixos-image-set-target flake-ref host))
    (each attr (nix/nixos-image-attrs flake-ref host)
      (printf "%s" attr))))

(defn- build-image [flake-ref host variant]
  (let [variant (normalize-variant variant)
        target (nix/nixos-image-target flake-ref host variant)]
    (if (dryrun?)
      (echof "DRYRUN: nix build --impure %s" target)
      (do
        (let [attrs (nix/nixos-image-attrs flake-ref host)]
          (unless (index-of variant attrs)
            (abort "Host %s has no system.build.images.%s image output" host variant)))
        (nix/build "--impure" target)))))

(defcmd image [_ subcmd host & args
               &opts flake-opt ["--flake" flake-opt]]
  (unless host
    (abort usage))
  (let [flake-ref (or flake-opt (path :home))]
    (case* subcmd
      "list" (if (empty? args)
               (list-images flake-ref host)
               (abort usage))
      "build" (if (<= (length args) 1)
                (build-image flake-ref host (first args))
                (abort usage))
      (abort usage))))
