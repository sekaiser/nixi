#!/usr/bin/env janet
# Inspect and dispatch host-related commands.
#
# SYNOPSIS:
#   host doctor HOST [--flake FLAKE] [--storage]
#   host explain HOST [--flake FLAKE]
#   host list [--flake FLAKE]
#   host COMMAND [ARGS...]
#
# SUBCOMMANDS:
#   doctor  Check evaluated host metadata; --storage opts into storage policy.
#   explain  Explain a declared host build target.
#   list  List flake hosts grouped by platform.

(use hey)
(use hey/nix)
(use hey/cmd)
(use hey/ssh)
(import spork/json)

(def- usage
  "Usage: hey host doctor HOST [--flake FLAKE] [--storage] | hey host explain HOST [--flake FLAKE] | hey host list [--flake FLAKE] | hey host COMMAND [ARGS...]")

(defn- list-hosts [flake-ref]
  (if (dryrun?)
    (do
      (echof "DRYRUN: nix eval --impure --json --no-write-lock-file %s#darwinConfigurations --apply builtins.attrNames" flake-ref)
      (echof "DRYRUN: nix eval --impure --json --no-write-lock-file %s#nixosConfigurations --apply builtins.attrNames" flake-ref))
    (do
      (each host (nix/darwin-hosts flake-ref)
        (printf "darwin\t%s" host))
      (each host (nix/nixos-hosts flake-ref)
        (printf "nixos\t%s" host)))))

(def- host-query (path :framework "runtime/hey/host-info.nix"))

(defn- host-info [flake-ref kind host]
  (json/decode
    (nix/eval-raw "--file" host-query "result"
      "--argstr" "flakeRef" (nix/eval-flake-ref (nix/flake-ref flake-ref (path :home)))
      "--argstr" "host" host
      "--argstr" "kind" (case kind :darwin "darwinConfigurations" :nixos "nixosConfigurations"))))

(defn- print-array-lines [value]
  (let [limit 80]
    (if (empty? value)
      (echof "  <none>")
      (do
        (var count 0)
        (each item value
          (when (< count limit)
            (echof "  %s" item))
          (++ count))
        (when (> count limit)
          (echof "  ... %d more" (- count limit)))))))

(defn- print-map-lines [value]
  (let [items (sort (pairs value))
        limit 80]
    (if (empty? value)
      (echof "  <none>")
      (do
        (var count 0)
        (each [key val] items
          (when (< count limit)
            (echof "  %s: %q" key val))
          (++ count))
        (when (> count limit)
          (echof "  ... %d more" (- count limit)))))))

(defn- print-json-lines [label value]
  (echof "%s:" label)
  (case (type value)
    :tuple
    (print-array-lines value)
    :array
    (print-array-lines value)
    :table
    (print-map-lines value)
    :struct
    (print-map-lines value)
    (echof "  %q" value)))

(defn- enabled-label [value]
  (if value "enabled" "disabled"))

(defn- summarize-profile-value [value]
  (case (type value)
    :table
    (if (has-key? value "enable")
      (enabled-label (get value "enable"))
      "configured")
    :struct
    (if (has-key? value "enable")
      (enabled-label (get value "enable"))
      "configured")
    :array
    (string/format "%d item(s)" (length value))
    (string value)))

(defn- print-profile-lines [value]
  (let [items (sort (pairs value))]
    (echof "profiles:")
    (if (empty? value)
      (echof "  <none>")
      (each [key val] items
        (echof "  %s: %s" key (summarize-profile-value val))))))

(defn- bool-label [value]
  (if value "enabled" "disabled"))

(defn- print-storage-policy [policy]
  (unless (empty? policy)
    (let [journald (get policy "journald" {})
          vm-image (get policy "vmImage" {})]
      (echof "storage policy:")
      (if (get journald "enable")
        (echof "  journald: SystemMaxUse=%s RuntimeMaxUse=%s"
               (get journald "systemMaxUse" "<unset>")
               (get journald "runtimeMaxUse" "<unset>"))
        (echof "  journald: disabled"))
      (echof "  fstrim: %s" (bool-label (get policy "fstrim")))
      (echof "  root noatime: %s" (bool-label (get policy "noatime")))
      (if (get vm-image "enable")
        (do
          (echof "  vm ssd optimizations: %s" (bool-label (get vm-image "ssdOptimizations")))
          (echof "  vm generation cleanup: %s, keep %s"
                 (bool-label (get vm-image "autoCleanGenerations"))
                 (string (get vm-image "keepGenerations" "<unset>"))))
        (echof "  vm generation cleanup: <not a vm-image host>")))))

(defn- policy-ok [label ok &opt detail]
  (if ok
    (echof :check "%s" label)
    (do
      (echof :error "%s" label)
      (when detail
        (echo :err detail))))
  ok)

(defn- doctor-host [flake-ref host storage?]
  (when (dryrun?)
    (echof "host: %s" host)
    (echof "flake: %s" flake-ref)
    (echof "DRYRUN: evaluate host metadata%s" (if storage? " and storage policy" ""))
    (break))
  (let [kind (nix/host-kind flake-ref host)]
    (unless kind
      (abort "Unknown host %s in %s" host flake-ref))
    (def info (host-info flake-ref kind host))
    (cond
      (not storage?)
      (do
        (echof :check "host metadata evaluates: %s (%s)" host (get info "system"))
        (echo "Storage policy checks are opt-in: add --storage."))
      (= kind :darwin)
      (echo :check "storage policy doctor skipped for darwin host")
      (let [policy (get info "storage")
            journald (get policy "journald" {})
            vm-image (get policy "vmImage" {})]
        (var ok true)
        (echof "host: %s" host)
        (echof "kind: nixos")
        (if (empty? policy)
          (do
            (echof :error "storage policy is available")
            (exit 1))
          (do
            (unless (policy-ok "journald storage is bounded"
                               (and (get journald "enable")
                                    (not (empty? (get journald "systemMaxUse" "")))
                                    (not (empty? (get journald "runtimeMaxUse" ""))))
                               (string/format "journald=%q" journald))
              (set ok false))
            (unless (policy-ok "fstrim is enabled" (get policy "fstrim"))
              (set ok false))
            (unless (policy-ok "root filesystem uses noatime" (get policy "noatime"))
              (set ok false))
            (when (get vm-image "enable")
              (unless (policy-ok "vm SSD optimizations are enabled" (get vm-image "ssdOptimizations"))
                (set ok false))
              (unless (policy-ok "vm generation cleanup is enabled" (get vm-image "autoCleanGenerations"))
                (set ok false))
              (unless (policy-ok "vm keeps at least one generation"
                                 (>= (get vm-image "keepGenerations" 0) 1))
                (set ok false)))
            (if ok
              (echo :check "host policy doctor passed")
              (exit 1))))))))

(defn- explain-host [flake-ref host]
  (when (dryrun?)
    (echof "host: %s" host)
    (echof "flake: %s" flake-ref)
    (echof "DRYRUN: resolve host kind from darwinConfigurations/nixosConfigurations")
    (echof "DRYRUN: evaluate host system, theme, eval target, and build target")
    (break))
  (let [kind (nix/host-kind flake-ref host)]
    (unless kind
      (abort "Unknown host %s in %s" host flake-ref))
    (let [build-target (nix/host-build-target flake-ref kind host)
          eval-target (nix/host-eval-target flake-ref kind host)
          info (host-info flake-ref kind host)]
      (echof "host: %s" host)
      (echof "kind: %s" (case kind :darwin "darwin" :nixos "nixos"))
      (echof "flake: %s" flake-ref)
      (echof "system: %s" (get info "system"))
      (echof "theme: %s" (get info "theme"))
      (echof "eval target: %s" eval-target)
      (echof "build target: %s" build-target)
      (print-profile-lines (get info "profiles"))
      (print-json-lines "enabled modules" (get info "enabledModules"))
      (print-storage-policy (get info "storage"))
      (case kind
        :darwin (echof "sync command: %s" (ssh/remote-command ["hey" "sync" "--flake" (string flake-ref "#" host)]))
        :nixos (echof "build command: %s" (ssh/remote-command ["hey" "check" "build" host "--flake" flake-ref]))))))

(defn- dispatch-host-bin [subcmd args]
  (if-let [resolved (resolve [(path :host "bin")] subcmd ;args)]
    (execute! resolved)
    (abort "%s: host command not found" subcmd)))

(defcmd host [_ subcmd & args
              &opts flake-opt ["--flake" flake-opt]
                     storage? --storage]
  (when (and storage? (not= subcmd "doctor"))
    (abort usage))
  (case* subcmd
    "doctor" (if (= 1 (length args))
               (doctor-host (or flake-opt (path :home)) (first args) storage?)
               (abort usage))
    "explain" (if (= 1 (length args))
                (explain-host (or flake-opt (path :home)) (first args))
                (abort usage))
    "list" (if (empty? args)
             (list-hosts (or flake-opt (path :home)))
             (abort usage))
    nil (abort usage)
    (dispatch-host-bin subcmd args)))
