(import spork/json)
(import spork/path)
(use ./lib)
(import ./subprocess)

(defn- capture-limit []
  (if-let [value (os/getenv "HEY_NIX_CAPTURE_LIMIT")]
    (let [number (scan-number value)]
      (unless (and (peg/match '(sequence (some (range "09")) -1) value)
                   (int? number) (> number 0))
        (error "HEY_NIX_CAPTURE_LIMIT must be a positive integer byte count"))
      number)
    (* 8 1024 1024)))

(def- output-query (path/join (path/dirname (dyn :current-file)) "flake-outputs.nix"))

(defmacro- without-nix-path [& body]
  (with-syms [$old]
    ~(let [,$old (os/getenv "NIX_PATH")]
       (os/setenv "NIX_PATH" nil)
       (defer (os/setenv "NIX_PATH" ,$old)
         ,;body))))

(defn nix/split-flake-ref [flake &opt default-ref]
  (let [[ref host] (string/split "#" flake 0 2)]
    (if host
      [(if (and default-ref (or (= ref ".") (= ref ""))) default-ref ref) host]
      [(if (and default-ref (or (= flake ".") (= flake ""))) default-ref flake) nil])))

(defn nix/flake-ref [flake &opt default-ref]
  (first (nix/split-flake-ref flake default-ref)))

(defn nix/eval-flake-ref [ref]
  # builtins.getFlake does not apply the CLI's local-directory shorthand.
  (if (or (string/has-prefix? "." ref) (path/directory? ref))
    (path/abspath ref)
    ref))

(defn nix/flake-host [flake]
  (or (last (nix/split-flake-ref flake))
      (string/replace ".#" "" flake)))

(defn- attr-segment [name]
  # The CLI selection-path parser is not the Nix expression parser: quoted
  # segments preserve backslashes literally, and cannot escape double quotes.
  (when (or (empty? name) (string/find "\"" name))
    (error "Nix CLI attribute names must be nonempty and cannot contain double quotes"))
  (if (peg/match '(* (+ :a "_") (any (+ :w (set "_-'"))) -1) name)
    name
    (string "\"" name "\"")))

(defn nix/flake-target [flake-ref & segments]
  (string flake-ref "#" (string/join (map attr-segment segments) ".")))

(defn nix/darwin-system-target [flake-ref host]
  (nix/flake-target flake-ref "darwinConfigurations" host "system"))

(defn nix/darwin-system-drv-path-target [flake-ref host]
  (nix/flake-target flake-ref "darwinConfigurations" host "system" "drvPath"))

(defn nix/nixos-toplevel-target [flake-ref host]
  (nix/flake-target flake-ref "nixosConfigurations" host "config" "system" "build" "toplevel"))

(defn nix/nixos-toplevel-drv-path-target [flake-ref host]
  (nix/flake-target flake-ref "nixosConfigurations" host "config" "system" "build" "toplevel" "drvPath"))

(defn nix/nixos-iso-target [flake-ref host]
  (nix/flake-target flake-ref "nixosConfigurations" host "config" "system" "build" "isoImage"))

(defn nix/nixos-image-target [flake-ref host &opt variant]
  (nix/flake-target flake-ref "nixosConfigurations" host "config" "system" "build" "images" (or variant "qemu-efi")))

(defn nix/nixos-image-drv-path-target [flake-ref host &opt variant]
  (string (nix/nixos-image-target flake-ref host variant) ".drvPath"))

(defn nix/nixos-image-set-target [flake-ref host]
  (nix/flake-target flake-ref "nixosConfigurations" host "config" "system" "build" "images"))

(defn nix/eval-json-argv [attr &opt apply]
  (let [argv @["nix" "eval" "--impure" "--json"
               "--no-write-lock-file"
               attr]]
    (when apply
      (array/push argv "--apply")
      (array/push argv apply))
    argv))

(defn nix/eval-json [attr &opt apply]
  (let [argv (nix/eval-json-argv attr apply)]
    (without-nix-path
      (json/decode (string/trim (subprocess/output argv nil (capture-limit)))))))

(defn nix/eval-raw-argv [& args]
  @["nix" "eval" "--impure" "--raw"
    "--no-write-lock-file"
    ;args])

(defn nix/eval-raw [& args]
  (let [argv (nix/eval-raw-argv ;args)]
    (without-nix-path
      (string/trim (subprocess/output argv nil (capture-limit))))))

(defn nix/current-system []
  (nix/eval-raw "--expr" "builtins.currentSystem"))

(defn nix/flake-output-names [flake-ref output]
  (nix/eval-json
    (nix/flake-target flake-ref output)
    "builtins.attrNames"))

(defn- optional-output-names [flake-ref & attr-path]
  # Evaluate the flake itself, not its default package. Missing optional
  # outputs are empty, but genuine evaluation failures must still propagate.
  (json/decode
    (nix/eval-raw "--file" output-query "result"
      "--argstr" "flakeRef" (nix/eval-flake-ref flake-ref)
      "--argstr" "attrPath" (string (json/encode attr-path)))))

(defn nix/flake-check-names [flake-ref system]
  (optional-output-names flake-ref "checks" system))

(defn nix/flake-check-target [flake-ref system check]
  (nix/flake-target flake-ref "checks" system check))

(defn nix/darwin-hosts [flake-ref]
  (optional-output-names flake-ref "darwinConfigurations"))

(defn nix/nixos-hosts [flake-ref]
  (optional-output-names flake-ref "nixosConfigurations"))

(defn nix/nixos-image-attrs [flake-ref host]
  (nix/eval-json
    (nix/nixos-image-set-target flake-ref host)
    "builtins.attrNames"))

(defn nix/host-kind [flake-ref host]
  (cond
    (index-of host (nix/darwin-hosts flake-ref)) :darwin
    (index-of host (nix/nixos-hosts flake-ref)) :nixos
    nil))

(defn nix/host-eval-target [flake-ref kind host]
  (case kind
    :darwin (nix/darwin-system-drv-path-target flake-ref host)
    :nixos  (nix/nixos-toplevel-drv-path-target flake-ref host)))

(defn nix/host-build-target [flake-ref kind host]
  (case kind
    :darwin (nix/darwin-system-target flake-ref host)
    :nixos  (nix/nixos-toplevel-target flake-ref host)))

(defn nix/nom-available? []
  (truthy? (path/find "nom")))

(defn nix/prefer-nom? []
  (and (= "1" (os/getenv "HEY_NIX_USE_NOM"))
       (nix/nom-available?)))

(defn nix/build-argv [& args]
  @[
    ;(if (nix/prefer-nom?)
       ["nom" "build"]
       ["nix" "build"])
    ;args])

(defn nix/build [& args]
  (let [argv (nix/build-argv ;args)
        status (without-nix-path (os/execute argv :p))]
    (unless (= 0 status)
      (eprintf "Build failed: %s\n" (string/join argv " "))
      (eprintf "Tip: rerun with -? for more command context, or inspect the failed derivation with nix log.\n")
      (os/exit status))))

(defn nix/build-output [& args]
  (without-nix-path
    # Build diagnostics stream to stderr; only result paths are captured.
    # Builds and evaluations intentionally have no short probe deadline.
    (string/trim (subprocess/output (nix/build-argv ;args) nil (capture-limit) true))))
