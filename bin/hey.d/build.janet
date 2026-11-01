#!/usr/bin/env janet
# Build framework packages or consumer host artifacts.
#
# SYNOPSIS:
#   build [-a]
#   build iso
#   build vm [ARGS...]
#   build vm-with-bootloader [ARGS...]
#
# SUBCOMMANDS:
#   iso                 Build the current host ISO image.
#   vm                  Build the current host VM image.
#   vm-with-bootloader  Build the current host VM image with bootloader.
#
# OPTIONS:
#   -a
#     Also build the pinned Janet dependency package.

(use hey)
(use hey/nix)
(use hey/cmd)

(defn- build-vm [type & args]
  (echo :g "> Building a VM of this flake...")
  (hey sync -- ,(string "build-" type) ,;args))

(defn- build-iso [& args]
  (let [target (nix/nixos-iso-target (path :home) (flake :host))]
    (echo :g "> Building an ISO for this host...")
    (if (dryrun?)
      (echof "DRYRUN: nix build %s --out-link result-iso --print-out-paths" target)
      (nix/build
        target
        "--out-link" "result-iso"
        "--print-out-paths"))))

(defn- build-hey [&opt all?]
  (echof :g "> Building hey%s..."
         (if all? " and pinned Janet dependencies" ""))
  (each package (if all? ["hey" "hey-janet-deps"] ["hey"])
    # Consumers need not re-export framework packages. Keep result links in
    # the caller's directory, never in a potentially read-only framework tree.
    (let [args @["--impure" "--no-write-lock-file"
                 (string "path:" (path :framework) "#" package)
                 "--out-link" (if (= package "hey") "result" "result-hey-janet-deps")]]
      (if (dryrun?)
        (echo "DRYRUN: " (string/join (nix/build-argv ;args) " "))
        (nix/build ;args))))
  (echo :check "Done!"))

(defcmd build [_ cmd & args]
  (case* cmd
    "iso" (if (empty? args)
            (build-iso)
            (abort "Usage: hey build iso"))
    ["vm" "vm-with-bootloader"] (build-vm cmd ;args)
    nil (build-hey false)
    "-a" (if (empty? args)
           (build-hey true)
           (abort "Usage: hey build [-a]"))
    (if (string/has-prefix? "-" cmd)
      (abort "Usage: hey build [-a]")
      (abort "Unknown build command: %s" cmd))))
