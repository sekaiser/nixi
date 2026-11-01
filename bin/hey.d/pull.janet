#!/usr/bin/env janet
# Update one or more flake inputs.
#
# SYNOPSIS:
#   pull
#   pull [INPUTS]...
#   pull -o [INPUT@REV|INPUT=FLAKE_URI]...
#
# EXAMPLES:
#   hey pull
#     Update all flakes:
#   hey pull waybar 'hypr*'
#     Pull only specific inputs (globs are recognized):
#   hey pull -o waybar@0b6476da32d181ee6b2cabdc5205a46a90521a75 ...
#   hey pull -o waybar=github:aForkOf/Waybar ...
#     A more concise command for repinning inputs.

(use hey)
(use hey/cmd)
(import hey/glob)

(var- *metadata* nil)

(defn metadata []
  (unless *metadata*
    (set *metadata*
         (json/decode ($<_ nix flake metadata --json --no-write-lock-file ,(path :home))
                      :keywords true)))
  *metadata*)

(defn- parse-override [arg]
  (or (peg/match '(sequence
                   (<- (some (choice (range "az" "AZ" "09") (set "_-"))))
                   (<- (set "=@"))
                   (<- (some 1)) -1) arg)
      (abort "Malformed input spec: %s" arg)))

(defn- revision-uri [name rev]
  (if (dryrun?)
    (string/format "<locked-%s-input-at-%s>" name rev)
    (let [locks (get (metadata) :locks)
          nodes (get locks :nodes)
          root (keyword (get locks :root "root"))]
      (defn follow [node names seen]
        (if (empty? names)
          node
          (let [key [node names]]
            (when (index-of key seen)
              (abort "Cyclic input follows: %s" name))
            (let [ref (get-in nodes [node :inputs (keyword (first names))])
                  next (cond (string? ref) (keyword ref)
                             (indexed? ref) (follow root ref [;seen key])
                             (abort "Unknown input: %s" name))]
              (follow next (slice names 1) [;seen key])))))
      (let [input (get-in nodes [(follow root [name] []) :original])
            type (input :type)]
        (unless (and (index-of type ["github" "gitlab" "sourcehut"])
                     (input :owner) (input :repo))
          (abort "Input %s does not support @REV shorthand; use %s=FLAKE_URI" name name))
        (string/format "%s:%s/%s/%s" type (input :owner) (input :repo) rev)))))

(defn- override-inputs [args]
  (let [flake-args @[]
        names @[]]
    (each arg args
      (let [[name kind value] (parse-override arg)]
        (array/push names name)
        (array/push flake-args ["--override-input" name
                               (if (= kind "@") (revision-uri name value) value)])))
    (when (empty? flake-args)
      (abort "No flakes to override"))
    (echo :g "> Updating overridden inputs...")
    (do? $ nix flake update --flake ,(path :home) --refresh ,;(flatten flake-args) ,;names)))

(defcmd pull [_ & args &opts override? [-o --override]]
  (cond
    override?
    (override-inputs args)

    (empty? args)
    (do
      (echo :g "> Updating all inputs...")
      (do? $ nix flake update --flake ,(path :home) --impure))

    (dryrun?)
    (do
      (echo :g "> Updating matching inputs:")
      (each arg args (echof "  - %s" arg))
      (do? $ nix flake update --flake ,(path :home) --impure ,;args))

    (let [locks (get (metadata) :locks)
          inputs (keys (get-in locks [:nodes (keyword (get locks :root "root")) :inputs]))
          includes (filter |(not (string/has-prefix? "!" $)) args)
          excludes (map |(string/slice $ 1) (filter |(string/has-prefix? "!" $) args))
          targets @{}]
      (when (index-of "" excludes)
        (abort "An input exclusion must contain a pattern after !"))
      (each i inputs
        (when (and (or (empty? includes) (find |(glob/match* $ i) includes))
                   (not (find |(glob/match* $ i) excludes)))
          (put targets (string i) true)))
      (when (empty? targets)
        (abort "No matching inputs"))
      (echo :g "> Updating matching inputs:")
      (eachk t targets (echof "  - %s" t))
      (do? $ nix flake update --flake ,(path :home) --impure ,;(sort (keys targets))))))
