(use hey/nix)
(use ./lib)
(import spork/path)
(import ./process)

(defn image/slurp [args]
  (string/trim (process/output args 30)))

(defn image/build-qemu-efi [flake-ref host]
  (nix/build-output
    "--impure"
    "--option" "keep-outputs" "true"
    "--option" "keep-derivations" "true"
    "--print-out-paths"
    (nix/nixos-image-target flake-ref host)))

(defn image/build-toplevel [flake-ref host]
  (nix/build-output
    "--impure"
    "--print-out-paths"
    (nix/nixos-toplevel-target flake-ref host)))

(defn image/qcow-image [image-out]
  (or
    (first
      (seq [name :in (os/dir image-out)
            :let [path (string image-out "/" name)]
            :when (string/has-suffix? ".qcow2" name)
            :when (= :file (os/stat path :mode))]
        path))
    ""))

(defn image/utm-workdir []
  (path/join (path/user-home) "Library/Containers/com.utmapp.UTM/Data/Documents/HeyImages"))

(defn image/prepare-utm-copy [flake-ref flake]
  (let [host (nix/flake-host flake)
        out (image/build-qemu-efi flake-ref host)
        source (image/qcow-image out)
        dir (image/utm-workdir)]
    (when (empty? source)
      (error (string/format "No qcow2 image found in %s" out)))
    (path/mkdirp dir)
    # Never overwrite a previous image or derive a disk path from the VM name.
    (let [stage (image/slurp @["mktemp" "-d" (path/join dir ".nixi-image.XXXXXXXXXX")])
          target (path/join stage "disk.img")]
      (var ready? false)
      (defer (unless ready? (path/rmtree stage))
        (os/execute @("qemu-img" "convert" "-p" "-O" "raw" source target) :px)
        (unless (and (= :file (os/lstat target :mode)) (> (os/stat target :size) 0))
          (error "Converted UTM image is missing, empty, or not a regular file"))
        (os/execute @("qemu-img" "info" "-f" "raw" target) :px)
        (os/chmod target 8r600)
        (set ready? true)
        target))))
