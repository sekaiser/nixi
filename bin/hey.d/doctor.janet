#!/usr/bin/env janet
# Diagnose local system health issues.
#
# SYNOPSIS:
#   doctor
#   doctor agents
#   doctor env
#   doctor fix zsh-cache|tmux-env|stale-store-paths
#   doctor nix
#   doctor secrets [--strict]
#   doctor shell [--profile]
#   doctor sync
#   doctor zed
#
# SUBCOMMANDS:
#   agents  Check configured local agent commands and existing Codex state.
#   doctor  Run the daily health check, including SSH process/tunnel state.
#   env  Check inferred hey/flake environment context.
#   fix  Run an explicit, narrow remediation.
#   nix  Check Nix daemon/store health and common stuck-process patterns.
#   secrets  Report inline secret markers without printing secret values.
#   shell  Check interactive shell tooling and state paths.
#   sync  Check local rebuild/sync assumptions.
#   zed  Check managed Zed settings and extension drift.
#
# OPTIONS:
#   --quiet
#     Only print warnings, errors, and final status. This is the default.
#   --verbose
#     Print successful checks and detail lines too.
#   --profile
#     With `doctor shell`, measure interactive zsh startup time.
#   --strict
#     With `doctor secrets` or the daily doctor, fail on marker findings.
#     Secret scan exits: 0 clean, 1 strict findings, 2 incomplete/failed scan.

(use hey)
(use hey/cmd)
(import spork/json)
(import hey/system)

(def- usage
  "Usage: hey doctor [--quiet|--verbose] [agents|env|nix|secrets|shell|sync|zed] | hey doctor [secrets] --strict | hey doctor fix zsh-cache|tmux-env|stale-store-paths")

(defdyn *doctor-verbose*)
(defdyn *doctor-strict*)

(defn- verbose? []
  (dyn :doctor-verbose false))

(defn- detail [message & args]
  (when (verbose?)
    (echof message ;args)))

(defn- success [label]
  (when (verbose?)
    (echof :check "%s" label))
  true)

(defn- failure [label &opt detail]
  (echof :error "%s" label)
  (when (and detail (not (empty? detail)))
    (echo :err detail))
  false)

(defn- warning [label &opt detail]
  (echof :warn "%s" label)
  (when (and detail (not (empty? detail)))
    (echo :err detail))
  false)

(import hey/process)
(import hey/input)
(import hey/process-table)
(def- run process/probe)

(defn- nonempty-lines [text]
  (filter |(not (empty? $)) (string/split "\n" text)))

(defn- contains? [haystack needle]
  (not (nil? (string/find needle haystack))))

(def- ps-command-result process-table/snapshot)

(defn- ps-lines-matching [lines needle]
  (filter |(contains? $ needle) lines))

(def- process-fields process-table/fields)

(defn- u-state? [line]
  (contains? ((process-fields line) :stat) "U"))

(defn- unique-lines [lines]
  (var seen @{})
  (var out @[])
  (each line lines
    (unless (in seen line)
      (put seen line true)
      (array/push out line)))
  out)

(defn- print-lines [lines]
  (string/join lines "\n"))

(defn- check-present [label value]
  (if (and value (not (empty? value)))
    (do
      (success label)
      (detail "%s: %s" label value)
      true)
    (failure label)))

(defn- check-directory [label dir]
  (if (and dir (path/directory? dir))
    (do
      (success label)
      (detail "%s: %s" label dir)
      true)
    (failure label dir)))

(defn- check-command-available [name]
  (if (path/find name)
    (success (string name " command is available"))
    (failure (string name " command is available"))))

(defn- check-file [label file]
  (if (and file (path/file? file))
    (do
      (success label)
      (detail "%s: %s" label file)
      true)
    (failure label file)))

(defn- command-output-trimmed [args]
  (let [result (run args)]
    (if (= 0 (result :status))
      (string/trim (result :out)))))

(defn- line-value [text key]
  (let [prefix (string key "=")]
    (first
      (keep |(if (string/has-prefix? prefix $)
               (string/slice $ (length prefix)))
            (nonempty-lines text)))))

(defn- doctor-mode-args []
  (if (verbose?) @["--verbose"] @["--quiet"]))

(defn- run-doctor-command [subcmd]
  (let [mode (doctor-mode-args)
        _ (when (and (= subcmd "secrets") (dyn :doctor-strict false))
            (array/push mode "--strict"))]
    (if (dryrun?)
      (do
        (echof "DRYRUN: hey doctor %s %s" subcmd (string/join mode " "))
        true)
      (let [args @[(path :bin "hey") "doctor" subcmd ;mode]
            status (with-envvars ["HEY_DOCTOR_CALLER_PATH" (or (os/getenv "HEY_DOCTOR_CALLER_PATH") invocation-path)]
                     (os/execute args :p))]
        (= 0 status)))))

(defn- run-command [args]
  (if (dryrun?)
    (do
      (echof "DRYRUN: %s" (string/join args " "))
      true)
    (let [status (execute-clean args)]
      (= 0 status))))

(defn- doctor-all []
  (var ok true)
  (each subcmd ["env" "nix" "secrets" "sync"]
    (unless (run-doctor-command subcmd)
      (set ok false)))
  (when (flake/info :enabled :shell)
    (unless (run-doctor-command "shell") (set ok false)))
  (unless (run-command @[(path :bin "hey") "ssh" "doctor" ;(doctor-mode-args)])
    (set ok false))
  (if ok
    (echo :check "daily doctor passed")
    (exit 1)))

(defn- doctor-env []
  (var ok true)
  (let [home (flake :path)
        host (flake :host)
        user (flake :user)
        theme (flake :theme)]
    (unless (check-directory "dotfiles path" home)
      (set ok false))
    (unless (check-present "host" host)
      (set ok false))
    (unless (check-present "user" user)
      (set ok false))
    (if (and theme (not (empty? theme)))
      (do
        (success "theme")
        (detail "theme: %s" theme))
      (warning "theme is not set"))
    # Hosts may be inline descriptors, flat files, or discovered recursively.
    # Their source layout is not a CLI contract.
    (unless (check-file "flake entrypoint" (path/join home "flake.nix"))
      (set ok false))
    (if (os/getenv "HEYENV")
      (warning "HEYENV override is set")
      (success "HEYENV override is not required"))
    (if ok
      (echo :check "environment doctor passed")
      (exit 1))))

(defn- agent-manifest-file [name]
  (path :data "agents" (string name ".json")))

(defn- read-agent-manifest [name fallback]
  (let [file (agent-manifest-file name)]
    (if (path/file? file)
      (json/decode (slurp file))
      fallback)))

(defn- read-codex-agent-manifest []
  (read-agent-manifest
    "codex"
    {
      "codexHome" (or (os/getenv "CODEX_HOME")
                      (path/join (os/getenv "HOME") ".codex"))
      "plugins" @[]
      "mcpServers" @[]
    }))

(defn- read-omp-agent-manifest []
  (if (path/file? (agent-manifest-file "omp"))
    (read-agent-manifest
      "omp"
      {
        "configFile" ".omp/agent/config.yml"
        "checkConfig" true
        "modelRoles" @{}
      })))

(defn- capability-manifest-file []
  (path :data "capabilities.json"))

(defn- read-capability-manifest []
  (let [file (capability-manifest-file)]
    (if (path/file? file)
      (try
        (json/decode (slurp file))
        ([err fib]
         (failure "capability manifest contains valid JSON" (string err))
         nil))
      {})))

(defn- string-list? [value]
  (and (indexed? value)
       (all string? value)))

(defn- string-map? [value]
  (and (dictionary? value)
       (all string? (keys value))
       (all string? (values value))))

(defn- capability-shape? [capability]
  (and (dictionary? capability)
       (string-list? (get capability "commands" @[]))
       (string-map? (get capability "directories" @{}))
       (string-map? (get capability "files" @{}))))

(defn- validate-capability-manifest [manifest]
  (cond
    (not (dictionary? manifest))
    (failure "capability manifest root is an object")

    (not= 1 (get manifest "version"))
    (failure "capability manifest schema version 1 is supported"
             (string/format "found version: %q" (get manifest "version")))

    (not (dictionary? (get manifest "groups")))
    (failure "capability manifest groups is an object")

    (do
      (var ok true)
      (eachp [group capabilities] (get manifest "groups")
        (if (and (string? group) (dictionary? capabilities))
          (eachp [name capability] capabilities
            (unless (and (string? name) (capability-shape? capability))
              (set ok false)
              (failure
                (string/format "capability manifest entry %s.%s is valid" group name)
                "expected commands: string[], directories: {string: string}, files: {string: string}")))
          (do
            (set ok false)
            (failure "capability manifest group is valid"
                     "expected a named object of capabilities"))))
      (when ok
        (success "capability manifest schema version 1 is valid"))
      ok)))

(defn- check-capability [name capability]
  (var ok true)
  (detail "capability: %s" name)
  (each command (get capability "commands" @[])
    (unless (check-command-available command)
      (set ok false)))
  (eachp [label dir] (get capability "directories" @{})
    (unless (check-directory label dir)
      (set ok false)))
  (eachp [label file] (get capability "files" @{})
    (unless (check-file label file)
      (set ok false)))
  ok)

(defn- check-capability-group [group]
  (var ok true)
  (let [file (capability-manifest-file)]
    (if (path/file? file)
      (do
        (success "generated capability manifest exists")
        (detail "capability manifest: %s" file)
        (let [manifest (read-capability-manifest)]
          (if (and manifest (validate-capability-manifest manifest))
            (eachp [name capability] (get (get manifest "groups") group @{})
              (unless (check-capability name capability)
                (set ok false)))
            (set ok false))))
      (do
        (set ok false)
        (failure "generated capability manifest exists"))))
  ok)

(defn- check-agent-entries [label entries]
  (var ok true)
  (eachp [name status] entries
    (if (= status "configured")
      (success (string label " configured: " name))
      (do (set ok false) (failure (string label " " status ": " name)))))
  ok)

(defn- process-alive? [pid]
  (and pid
       (not (empty? pid))
       (= 0 (os/execute @["kill" "-0" pid] :p))))

(defn- codegraph-line? [line]
  (contains? line "codegraph.js serve --mcp"))

(defn- codegraph-daemon-line? [line]
  (contains? line " --path "))

(defn- codegraph-proxy-line? [line]
  (and (codegraph-line? line)
       (not (codegraph-daemon-line? line))))

(defn- codegraph-daemon-root [line]
  (let [command ((process-fields line) :command)
        marker " --path "
        idx (string/find marker command)]
    (if idx
      (string/slice command (+ idx (length marker))))))

(defn- agent-line? [line]
  (or (contains? line "codex resume")
      (contains? line " omp --resume")
      (contains? line "omp --resume")
      (contains? line " omp ")
      (string/has-prefix? "omp " line)))

(defn- zombie-line? [line]
  (contains? ((process-fields line) :stat) "Z"))

(defn- agent-pid-map [lines]
  (var pids @{})
  (each line lines
    (let [fields (process-fields line)]
      (when (agent-line? (fields :command))
        (put pids (fields :pid) fields))))
  pids)

(defn- codegraph-daemon-pidfiles [roots]
  (var files @[])
  (each root roots
    (let [file (path/join root ".codegraph" "daemon.pid")]
      (when (path/file? file)
        (array/push files file))))
  files)

(defn- daemon-pidfile-root [file]
  (path/dirname (path/dirname file)))

(defn- read-daemon-pidfile [file]
  (ignore-errors (json/decode (slurp file))))

(defn- check-codegraph-processes []
  (var ok true)
  (let [ps-result (ps-command-result)]
    (when (not= 0 (ps-result :status))
      (failure "Codegraph process table probe failed"
               (if (empty? (ps-result :err)) (ps-result :out) (ps-result :err)))
      (break false))
    (let [ps-out (ps-result :out)
        lines (nonempty-lines ps-out)
        agent-pids (agent-pid-map lines)
        codegraph-lines (filter codegraph-line? lines)
        proxy-lines (filter codegraph-proxy-line? codegraph-lines)
        daemon-lines (filter codegraph-daemon-line? codegraph-lines)
        zombie-lines (filter zombie-line? codegraph-lines)
        project-roots (unique-lines
                        (array/concat
                          @[(os/cwd)]
                          (array ;(keep codegraph-daemon-root daemon-lines))))
        pidfiles (codegraph-daemon-pidfiles project-roots)
        stale-pidfiles @[]]
    (success "Codegraph process table is readable")
    (if (empty? codegraph-lines)
      (success "no Codegraph MCP processes found")
      (success (string/format "%d Codegraph MCP process(es) found" (length codegraph-lines))))
    (if (empty? daemon-lines)
      (success "no Codegraph daemon process found")
      (do
        (success (string/format "%d Codegraph daemon process(es) found" (length daemon-lines)))
        (each line daemon-lines
          (detail "Codegraph daemon: %s" line))))
    (if (empty? proxy-lines)
      (success "no Codegraph proxy processes found")
      (do
        (success (string/format "%d Codegraph proxy process(es) found" (length proxy-lines)))
        (each line proxy-lines
          (let [fields (process-fields line)
                parent (get agent-pids (fields :ppid))]
            (if parent
              (success (string/format "Codegraph proxy %s owned by agent %s" (fields :pid) (parent :pid)))
              (warning (string/format "Codegraph proxy %s has no visible agent owner" (fields :pid)) line))))))
    (each file pidfiles
      (let [lock (read-daemon-pidfile file)
            pid (if lock (get lock "pid"))
            pid-str (if pid (string pid) "")]
        (if (process-alive? pid-str)
          (do
            (success (string/format "Codegraph daemon pidfile is live: %s" (daemon-pidfile-root file)))
            (detail "Codegraph daemon pidfile: %s" file))
          (array/push stale-pidfiles file))))
    (if (empty? stale-pidfiles)
      (success "no stale Codegraph daemon pidfiles found")
      (do
        (each file stale-pidfiles
          (warning (string/format "stale Codegraph daemon pidfile: %s" file)))
        (detail "repair: codegraph unlock PROJECT or remove the stale daemon.pid after review")))
    (if (empty? zombie-lines)
      (success "no zombie Codegraph processes found")
      (do
        (set ok false)
        (failure (string/format "%d zombie Codegraph process(es) found" (length zombie-lines))
                 (print-lines zombie-lines))))
    ok)))

(defn- doctor-agents []
  (when (dryrun?)
    (echof "DRYRUN: check generated capability manifest")
    (echof "DRYRUN: check generated agent manifests")
    (echof "DRYRUN: check existing Codex state directory and config")
    (echof "DRYRUN: check declared Codex commands, plugins, MCP servers, and harnessing tools")
    (echof "DRYRUN: classify Codegraph daemon and proxy process state")
    (break))
  (var ok true)
  (let [codex-manifest (read-codex-agent-manifest)
        omp-manifest (read-omp-agent-manifest)
        codex-home (get codex-manifest "codexHome")
        codex-config (path/join codex-home "config.toml")
        plugins (get codex-manifest "plugins" @[])
        mcp-servers (get codex-manifest "mcpServers" @[])]
    (unless (check-capability-group "agents")
      (set ok false))
    (when (path/file? (agent-manifest-file "codex"))
      (success "generated Codex agent manifest exists")
      (detail "Codex agent manifest: %s" (agent-manifest-file "codex")))
    (when (path/file? (agent-manifest-file "omp"))
      (success "generated omp tool manifest exists")
      (detail "omp tool manifest: %s" (agent-manifest-file "omp")))
    (when (or (path/file? (agent-manifest-file "codex")) (path/file? codex-config))
      (try
        (let [parsed (input/agent-config "codex" codex-config
                       {"plugins" plugins "mcpServers" mcp-servers})]
          (unless (check-agent-entries "Codex plugin" (parsed "plugins")) (set ok false))
          (unless (check-agent-entries "Codex MCP server" (parsed "mcpServers")) (set ok false)))
        ([err fib] (set ok false) (failure "Codex configuration could not be validated" (string err)))))
    (unless (check-codegraph-processes)
      (set ok false))
    (when omp-manifest
      (let [omp-config-file (path/join (os/getenv "HOME") (get omp-manifest "configFile"))
            omp-check-config? (get omp-manifest "checkConfig" true)
            omp-model-roles (get omp-manifest "modelRoles" @{})]
        (when omp-check-config?
          (try
            (let [parsed (input/agent-config "omp" omp-config-file {"modelRoles" omp-model-roles})]
              (unless (check-agent-entries "omp model role" (parsed "modelRoles")) (set ok false)))
            ([err fib] (set ok false) (failure "omp configuration could not be validated" (string err))))))))
  (if ok
    (echo :check "agents doctor passed")
    (exit 1)))

(defn- nix-daemon-version [line]
  (let [prefix "-nix-"
        suffix "/bin/nix-daemon"
        prefix-at (string/find prefix line)
        suffix-at (string/find suffix line)]
    (if (and (not (nil? prefix-at)) (not (nil? suffix-at)) (< prefix-at suffix-at))
      (string/slice line (+ prefix-at (length prefix)) suffix-at))))

(defn- daemon-versions [lines]
  (unique-lines
    (keep nix-daemon-version lines)))

(defn- nix-version? [value]
  (and (string? value) (<= (length value) 128)
       (peg/match '(* :d+ "." :d+ (any (+ (range "09" "az" "AZ") "." "+" "_" "-")) -1) value)))

(defn- nix-identity-probe [args]
  # Failed/partial probes may include NIX_CONFIG values or authenticated URLs.
  # Return only validated fields to callers, never raw streams or exceptions.
  (try (run args)
       ([err fib] {:status 126 :out "" :err ""})))

(defn- nix-client [label executable &opt cached]
  (if (nil? executable)
    (do (failure (string label " unavailable: executable not found")) nil)
    (let [resolved (ignore-errors (os/realpath executable))]
      (unless resolved
        (failure (string label " unavailable: executable could not be resolved"))
        (break nil))
      (detail "%s selected: %s" label (json/encode executable))
      (detail "%s resolved: %s" label (json/encode resolved))
      (let [same? (and cached (= resolved (cached :path)))
            result (if same? nil (nix-identity-probe @[resolved "--version"]))
            prefix "nix (Nix) "
            out (if result (string/trim (result :out)) "")
            version (if same? (cached :version)
                      (if (string/has-prefix? prefix out) (string/slice out (length prefix))))]
        (cond
          (and result (not= 0 (result :status)))
            (do (failure (string label " version probe failed; output withheld")) nil)
          (not (nix-version? version))
            (do (failure (string label " version could not be validated; output withheld")) nil)
          (do
            (detail "%s version: %s" label version)
            {:path resolved :version version}))))))

(defn- check-daemon [client]
  (unless client
    (failure "Connected Nix daemon version unknown: Hey client unavailable")
    (break nil))
  (let [result (nix-identity-probe @[(client :path) "store" "info" "--store" "daemon" "--json"])]
    (if (not= 0 (result :status))
      (let [err (string/ascii-lower (result :err))
            reason (cond
                     (or (contains? err "permission denied") (contains? err "operation not permitted")
                         (contains? err "access denied") (contains? err "not allowed")) "probe access denied"
                     (or (contains? err "connection refused") (contains? err "no such file or directory")) "connection unavailable"
                     "probe failed")]
        (failure (string "Connected Nix daemon " reason "; version unknown; output withheld"))
        nil)
      (try
        (let [info (json/decode (result :out) false true)]
          (unless (and (dictionary? info) (= "daemon" (get info "url")))
            (error "Invalid daemon info"))
          (success "Nix daemon store is reachable")
          (if (nil? (get info "version"))
            (do (failure "Connected Nix daemon version was not reported") nil)
            (do
              (unless (nix-version? (info "version")) (error "Invalid daemon version"))
              (detail "Connected Nix daemon version: %s" (info "version"))
              (info "version"))))
        ([err fib]
         (failure "Connected Nix daemon response could not be validated; output withheld")
         nil)))))

(defn- check-nix-identities []
  (let [caller-path (or (os/getenv "HEY_DOCTOR_CALLER_PATH") invocation-path)
        shell (nix-client "Invocation PATH Nix client" (path/find "nix" (string/split ":" caller-path)))
        client (nix-client "Hey Nix client" (path/find "nix") shell)
        daemon (check-daemon client)]
    (when (and shell client (not= (shell :path) (client :path)))
      (warning "Invocation PATH and Hey select different Nix executables"
               (string "shell: " (json/encode (shell :path)) "\nHey: " (json/encode (client :path)))))
    (each [label identity] [["Invocation PATH" shell] ["Hey" client]]
      (when (and identity daemon (not= (identity :version) daemon))
        (warning (string label " Nix client " (identity :version) " differs from connected daemon " daemon)
                 "Review client/profile selection; a version mismatch alone does not establish vulnerability or daemon age.")))
    (and shell client daemon true)))

(defn- check-processes []
  (var ok true)
  (let [result (ps-command-result)]
    (unless (= 0 (result :status))
      (failure "Nix process table probe failed" (result :err))
      (break false))
    (let [lines (nonempty-lines (result :out))
        daemon-lines (ps-lines-matching lines "nix-daemon")
        daemon-u (filter u-state? daemon-lines)
        optimise-lines (ps-lines-matching lines "nix-store --optimise")
        optimise-u (filter u-state? optimise-lines)
        rebuild-lines (ps-lines-matching lines "darwin-rebuild")
        build-lines (filter |(or (contains? $ "_nixbld")
                                  (contains? $ "home-manager-files")
                                  (contains? $ " lndir "))
                            lines)
        versions (daemon-versions lines)]

    (if (empty? daemon-lines)
      (do
        (set ok false)
        (failure "nix-daemon process exists"))
      (success "nix-daemon process exists"))

    (if (empty? daemon-u)
      (success "no nix-daemon worker is in U state")
      (do
        (set ok false)
        (failure "no nix-daemon worker is in U state" (print-lines daemon-u))))

    (if (empty? optimise-lines)
      (success "no nix-store --optimise process is running")
      (do
        (set ok false)
        (failure "no nix-store --optimise process is running" (print-lines optimise-lines))))

    (when (not (empty? optimise-u))
      (set ok false)
      (failure "no nix-store --optimise process is in U state" (print-lines optimise-u)))

    (if (<= (length versions) 1)
      (do
        (success "single nix-daemon executable version label observed")
        (when (not (empty? versions))
          (detail "nix-daemon process executable version label: %s" (first versions))))
      (do
        (set ok false)
        (failure "single nix-daemon executable version label observed" (print-lines versions))))

    (if (empty? rebuild-lines)
      (success "no darwin-rebuild process is active")
      (warning "darwin-rebuild process is active" (print-lines rebuild-lines)))

    (if (empty? build-lines)
      (success "no obvious Nix build worker is active")
      (warning "Nix build worker appears active" (print-lines build-lines)))

    ok)))

(defn- generated-config-files []
  [(path/join (or (os/getenv "XDG_CONFIG_HOME")
                  (path/join (os/getenv "HOME") ".config"))
              "zsh" "extra.zshrc")
   (path/join (or (os/getenv "XDG_CONFIG_HOME")
                  (path/join (os/getenv "HOME") ".config"))
              "tmux" "tmux.conf")])

(defn- store-source-paths [text]
  (var paths @[])
  (var rest text)
  (while (not (empty? rest))
    (if-let [start (string/find "/nix/store/" rest)]
      (let [from (string/slice rest start)
            end (or (find-index |(or (= $ (chr " "))
                                     (= $ (chr "\t"))
                                     (= $ (chr "\n"))
                                     (= $ (chr "'"))
                                     (= $ (chr "\""))
                                     (= $ (chr ")"))
                                     (= $ (chr "(")))
                                from)
                    (length from))
            candidate (string/slice from 0 end)]
        (array/push paths candidate)
        (set rest (string/slice from end)))
      (break)))
  (unique-lines paths))

(defn- check-generated-store-sources []
  (var ok true)
  (each file (generated-config-files)
    (when (path/file? file)
      (let [missing (filter |(not (path/exists? $))
                            (store-source-paths (slurp file)))]
        (if (empty? missing)
          (success (string "generated config store paths exist: " file))
          (do
            (set ok false)
            (failure (string "generated config has missing store paths: " file)
                     (print-lines missing)))))))
  ok)

(defn- check-untracked-source-files []
  (let [result (with-envvars ["LC_ALL" "C"]
                (run @["git" "-C" (path :home) "ls-files" "--others" "--exclude-standard" "--" "."] 30))]
    (cond
      (and (= 128 (result :status)) (contains? (result :err) "fatal: not a git repository"))
        (do
          (warning "untracked file check skipped: consumer is not in a Git worktree")
          true)
      (not (= 0 (result :status)))
        (failure "untracked file scan failed"
                 (if (empty? (result :err)) (result :out) (result :err)))
      (empty? (result :out))
        (success "no non-ignored untracked files under the consumer directory")
      (do
        (warning "non-ignored untracked files under the consumer directory"
                 (string/format "%s\nThese files may or may not be Nix inputs. Review and stage files referenced by your flake; Git-backed flakes omit untracked files."
                                (result :out)))
        true))))

(defn- check-build-sandbox []
  # Query one scalar, never the complete Nix config (which can contain tokens).
  # Even stderr or malformed scalar output may contain private configuration.
  (let [result (nix-identity-probe @["nix" "config" "show" "sandbox"])]
    (if (not (= 0 (result :status)))
      (failure "Could not inspect client build sandbox policy (diagnostic output withheld)")
      (case (string/trim (result :out))
        "true" (success "client requests build sandboxing; daemon enforcement not verified")
        "false" (do
          (warning "Client build sandbox is disabled; builds may access files and network outside the build directory")
          true)
        "relaxed" (do
          (warning "Client build sandbox is relaxed; some builds may bypass isolation")
          true)
        (failure "Unrecognized client build sandbox policy (diagnostic output withheld)")))))

(defn- doctor-nix []
  (if (dryrun?)
    (do
      (echof "DRYRUN: resolve invocation PATH and Hey Nix clients; run each --version")
      (echof "DRYRUN: Hey client: nix store info --store daemon --json")
      (echof "DRYRUN: nix config show sandbox (client policy only)")
      (echof "DRYRUN: %s" (string/join process-table/argv " "))
      (echof "DRYRUN: check nix-daemon, nix-store --optimise, darwin-rebuild, and build worker process state"))
    (do
      (var ok true)
      (unless (check-nix-identities)
        (set ok false))
      (unless (check-build-sandbox)
        (set ok false))
      (unless (check-processes)
        (set ok false))
      (unless (check-generated-store-sources)
        (set ok false))
      (unless (check-untracked-source-files)
        (set ok false))
      (if ok
        (echo :check "nix doctor passed")
        (exit 1)))))

(defn- fix-zsh-cache []
  (unless (run-command @[(path :bin "hey") "clean" "zsh"])
    (exit 1))
  (echo :check "zsh cache fix complete"))

(defn- fix-tmux-env []
  (let [dotfiles (path :home)
        dotfiles-bin (path :bin)]
    (if (dryrun?)
      (do
        (echof "DRYRUN: tmux set-environment -g DOTFILES_HOME %s" dotfiles)
        (echof "DRYRUN: tmux set-environment -g DOTFILES_BIN %s" dotfiles-bin)
        (echof "DRYRUN: hey reload tmux"))
      (do
        (unless (run-command @["tmux" "set-environment" "-g" "DOTFILES_HOME" dotfiles])
          (exit 1))
        (unless (run-command @["tmux" "set-environment" "-g" "DOTFILES_BIN" dotfiles-bin])
          (exit 1))
        (unless (run-command @[(path :bin "hey") "reload" "tmux"])
          (exit 1)))))
  (echo :check "tmux environment fix complete"))

(defn- fix-stale-store-paths []
  (if (dryrun?)
    (echof "DRYRUN: hey sync")
    (unless (run-command @[(path :bin "hey") "sync"])
      (exit 1)))
  (echo :check "stale generated store path fix complete"))

(defn- doctor-fix [target]
  (case* target
    "zsh-cache" (fix-zsh-cache)
    "tmux-env" (fix-tmux-env)
    "stale-store-paths" (fix-stale-store-paths)
    (abort usage)))

(defn- redact-secret-event [line]
  # JSON avoids confusing filenames containing colons/newlines with matches.
  # Never emit matched text or parser errors, even if the scan fails partway.
  (let [event (json/decode line false true)]
    (unless (and (dictionary? event)
                 (index-of (get event "type") ["begin" "match" "end" "summary"]))
      (error "Invalid scan event"))
    (when (= "match" (get event "type"))
      (let [data (event "data")
            file (get-in data ["path" "text"])
            number (data "line_number")]
        (unless (and (string? file) (int? number) (> number 0))
          (error "Invalid scan location"))
        (string (json/encode file) ":" number ": inline secret marker")))))

(defn- secret-scan-paths []
  (if-let [paths (os/getenv "HEY_DOCTOR_SECRET_PATHS")]
    (filter |(not (empty? $)) (string/split ":" paths))
    (filter path/exists? [(path :home) (path :modules)])))

(defn- inline-secret-markers []
  (let [paths (secret-scan-paths)
        pattern (string "(tskey-auth|::server:|SOPS_AGE_KEY=|AGE-SECRET-KEY-1|"
                        "password:[[:space:]]+[A-Za-z0-9+/=]{8,}|"
                        "\\$(1|5|6|y)\\$|\\$2[aby]\\$[0-9]{2}\\$|\\$argon2(id|i|d)\\$|"
                        "-----BEGIN (RSA |EC |DSA |OPENSSH |ENCRYPTED )?PRIVATE KEY-----|"
                        "-----BEGIN PGP PRIVATE KEY BLOCK-----|PuTTY-User-Key-File-[23]:)")]
    (when (empty? paths) (break {:out "" :status 2}))
    (let [result (run (array/concat
                      @["rg" "--no-config" "--json" "--hidden" "--no-ignore" "--glob" "!.git" "--glob" "!.direnv"
                        "--glob" "!node_modules" "--glob" "!target" "--glob" "!result" "--glob" "!result-*"
                        "-n" "-o" pattern "--"]
                      paths))]
      (if (and (index-of (result :status) [0 1]) (empty? (result :err)))
        (try
          (let [locations (sort (unique-lines (keep redact-secret-event (nonempty-lines (result :out)))))]
            (unless (= (= 0 (result :status)) (not (empty? locations)))
              (error "Scan status and events disagree"))
            {:out (print-lines locations) :status (result :status)})
          ([err fib] {:out "" :status 2}))
        {:out "" :status 2}))))

(defn- doctor-secrets []
  (if (dryrun?)
    (do
      (echof "DRYRUN: scan configured source roots for inline secret markers%s"
             (if (dyn :doctor-strict false) " (strict)" "")))
    (if (not (path/find "rg"))
      (do
        (failure "ripgrep command is available")
        (exit 2))
      (let [result (inline-secret-markers)]
        (case (result :status)
          0 (if (empty? (result :out))
              (echo :check "no inline secret markers found")
              (do
                (warning "inline secret markers found" (result :out))
                (echof :warn "move these to runtime secret files managed by your secret provider")
                (when (dyn :doctor-strict false) (exit 1))))
          1 (echo :check "no inline secret markers found")
          (do
            (failure "inline secret marker scan failed"
                     (string "Scan status " (result :status) "; check scan roots and permissions. Raw scanner output is withheld."))
            (exit 2)))))))

(defn- shell-profile []
  (if (dryrun?)
    (echof "DRYRUN: /usr/bin/time -p zsh -i -c exit")
    (do
      (echof :g "Measuring interactive zsh startup...")
      (for i 1 4
        (echof "run %d:" i)
        (let [status (os/execute @["time" "-p" "zsh" "-i" "-c" "exit"] :p)]
          (unless (= 0 status)
            (exit status)))))))

(defn- check-shell-prompt []
  (let [result (run @["zsh" "-ic" "current_tty=$(tty < /dev/tty 2>/dev/null || tty 2>/dev/null); pane_tty=; real_tmux=0; if [[ -n ${TMUX_PANE-} ]] && (( $+commands[tmux] )); then pane_tty=$(tmux display-message -p -t \"$TMUX_PANE\" '#{pane_tty}' 2>/dev/null); [[ -n $current_tty && $current_tty == $pane_tty ]] && real_tmux=1; fi; print -r -- term=${TERM-}; print -r -- inside_emacs=${INSIDE_EMACS-}; print -r -- tmux=${TMUX-}; print -r -- tmux_pane=${TMUX_PANE-}; print -r -- current_tty=$current_tty; print -r -- tmux_pane_tty=$pane_tty; print -r -- real_tmux=$real_tmux; print -r -- p10k_func=$+functions[p10k]; print -r -- left_count=${#POWERLEVEL9K_LEFT_PROMPT_ELEMENTS}; print -r -- right_count=${#POWERLEVEL9K_RIGHT_PROMPT_ELEMENTS}"])
        out (result :out)
        term (or (line-value out "term") "")
        inside-emacs (or (line-value out "inside_emacs") "")
        tmux (or (line-value out "tmux") "")
        tmux-pane (or (line-value out "tmux_pane") "")
        current-tty (or (line-value out "current_tty") "")
        tmux-pane-tty (or (line-value out "tmux_pane_tty") "")
        real-tmux (or (line-value out "real_tmux") "0")
        p10k (or (line-value out "p10k_func") "0")
        left-count (or (scan-number (or (line-value out "left_count") "0")) 0)
        right-count (or (scan-number (or (line-value out "right_count") "0")) 0)
        in-tmux? (= real-tmux "1")
        dumb? (= term "dumb")]
    (detail "shell TERM: %s" (if (empty? term) "<unset>" term))
    (when (not (empty? inside-emacs))
      (detail "shell INSIDE_EMACS: %s" inside-emacs))
    (when (or (not (empty? tmux)) (not (empty? tmux-pane)))
      (detail "shell TMUX env: %s" (if (empty? tmux) "<unset>" tmux))
      (detail "shell TMUX_PANE env: %s" (if (empty? tmux-pane) "<unset>" tmux-pane))
      (detail "shell tty: %s" (if (empty? current-tty) "<unset>" current-tty))
      (detail "tmux pane tty: %s" (if (empty? tmux-pane-tty) "<unresolved>" tmux-pane-tty)))
    (cond
      (not (= 0 (result :status)))
        (failure "zsh prompt diagnostic"
                 (if (empty? (result :err)) out (result :err)))
      dumb?
        (do
          (warning "Powerlevel prompt disabled for TERM=dumb"
                   "This is expected for TRAMP/comint-style editor shells; use a real terminal mode such as vterm for the full prompt.")
          true)
      (not (= p10k "1"))
        (failure "Powerlevel10k loads in interactive zsh" out)
      (< left-count 1)
        (failure "Powerlevel left prompt is configured" out)
      in-tmux?
        (success "Powerlevel prompt is configured; right prompt is suppressed inside tmux")
      (< right-count 1)
        (failure "Powerlevel right prompt is configured outside tmux" out)
      (do
        (success "Powerlevel prompt is configured outside tmux")
        true))))

(defn- doctor-shell [&opt profile?]
  (if (dryrun?)
    (do
      (echof "DRYRUN: check zsh, zoxide, and fzf commands")
      (echof "DRYRUN: check zsh history directory, zoxide data directory, and prompt state")
      (when profile?
        (shell-profile)))
    (do
      (var ok true)
      (unless (check-command-available "zsh")
        (set ok false))
      (unless (check-command-available "zoxide")
        (set ok false))
      (unless (check-command-available "fzf")
        (set ok false))
      (let [histfile (or (os/getenv "HISTFILE")
                         (string (or (os/getenv "XDG_STATE_HOME")
                                     (string (os/getenv "HOME") "/.local/state"))
                                 "/zsh/history"))
            histdir (path/dirname histfile)
            zodata (or (os/getenv "_ZO_DATA_DIR")
                       (string (or (os/getenv "XDG_DATA_HOME")
                                   (string (os/getenv "HOME") "/.local/share"))
                               "/zoxide"))]
        (unless (check-directory "zsh history directory" histdir)
          (set ok false))
        (if (path/exists? histfile)
          (success "zsh history file exists")
          (warning "zsh history file does not exist yet" histfile))
        (unless (check-directory "zoxide data directory" zodata)
          (set ok false)))
      (unless (check-shell-prompt)
        (set ok false))
      (when profile?
        (shell-profile))
      (if ok
        (echo :check "shell doctor passed")
        (exit 1)))))

(defn- doctor-sync []
  (if (dryrun?)
    (do
      (echof "DRYRUN: check hostname, flake host, dotfiles path, NIX_CONFIG, Nix/sudo, nom, and active hey"))
    (do
      (var ok true)
      (let [host (flake :host)
            hostname (command-output-trimmed @["hostname" "-s"])
            dotfiles (or (os/getenv "DOTFILES") (flake :path))
            dotfiles-home (or (os/getenv "DOTFILES_HOME") (flake :path))
            nix-config (or (os/getenv "NIX_CONFIG") "")]
        (if (= host hostname)
          (success "runtime host matches hostname")
          (do
            (set ok false)
            (failure "runtime host matches hostname"
                     (string/format "host=%s hostname=%s" host hostname))))
        (unless (check-directory "dotfiles path" dotfiles)
          (set ok false))
        (unless (check-directory "dotfiles home path" dotfiles-home)
          (set ok false))
        (if (and (= dotfiles dotfiles-home) (= dotfiles (flake :path)))
          (success "dotfiles env paths match flake path")
          (warning "dotfiles env paths differ"
                   (string/format "DOTFILES=%s\nDOTFILES_HOME=%s\nflake=%s"
                                  dotfiles dotfiles-home (flake :path))))
        # Store selection is consumer policy. Never echo raw configuration:
        # NIX_CONFIG can contain access-tokens or authenticated URLs.
        (detail "NIX_CONFIG: %s" (if (empty? nix-config) "<unset>" "<set; contents hidden>")))
      (unless (index-of (command-output-trimmed @["uname"]) ["Darwin" "Linux"])
        (set ok false)
        (failure "supported operating system"))
      (each command ["nix" "sudo"]
        (unless (check-command-available command) (set ok false)))
      (if-let [helper (os/getenv "HEY_SYSTEM_ACTIVATOR")]
        (unless (path/executable? helper)
          (set ok false)
          (failure "packaged system activator is available"))
        (detail "Source launcher: the activation helper will be built as the caller when needed."))
      (when (= "1" (os/getenv "HEY_NIX_USE_NOM"))
        (unless (path/find "nom")
          (warning "nom was requested but is unavailable; Nix will run without it")))
      (let [deployed (path/find "hey")
            source (path :bin "hey")]
        (if deployed
          (do
            (success "active hey command is available")
            (detail "hey: %s" deployed))
          (do
            (set ok false)
            (failure "active hey command is available")))
        (if (path/file? source)
          (success "source hey command exists")
          (do
            (set ok false)
            (failure "source hey command exists" source))))
      (if ok
        (echo :check "sync doctor passed")
        (exit 1)))))

(defn- zed-support-dir []
  (if (= "Darwin" (system/platform))
    (path/join (os/getenv "HOME") "Library" "Application Support" "Zed")
    (path/xdg :data "zed")))

(defn- zed-settings-file []
  (path/join (or (os/getenv "XDG_CONFIG_HOME")
                 (path/join (os/getenv "HOME") ".config"))
             "zed" "settings.json"))

(defn- zed-desired-file []
  (path/xdg :data "hey/zed-extensions.json"))

(defn- zed-installed-dir []
  (path/join (zed-support-dir) "extensions" "installed"))

(defn- installed-zed-extensions []
  (let [dir (zed-installed-dir)]
    (if (path/directory? dir)
      (let [result (run @["find" dir "-mindepth" "1" "-maxdepth" "1" "-type" "d" "-exec" "basename" "{}" ";"])]
        (unless (= 0 (result :status))
          (error "Zed extension discovery failed; installed state is unknown"))
        (sort (nonempty-lines (result :out))))
      [])))

(defn- desired-zed-extensions []
  (if (path/file? (zed-desired-file))
    (sort (get (json/decode (slurp (zed-desired-file))) "extensions" []))
    []))

(defn- member? [items item]
  (some (fn [candidate] (= candidate item)) items))

(defn- missing-items [wanted actual]
  (filter (fn [item] (not (member? actual item))) wanted))

(defn- doctor-zed []
  (when (dryrun?)
    (echof "DRYRUN: check Zed settings and desired extension manifest")
    (echof "DRYRUN: compare desired Zed extensions against installed extensions")
    (break))
  (var ok true)
  (unless (check-command-available "zed")
    (set ok false))
  (unless (path/file? (zed-settings-file))
    (set ok false)
    (failure "managed Zed settings file exists" (zed-settings-file)))
  (when (path/file? (zed-settings-file))
    (success "managed Zed settings file exists")
    (detail "zed settings: %s" (zed-settings-file)))
  (unless (path/file? (zed-desired-file))
    (set ok false)
    (failure "managed Zed extension manifest exists" (zed-desired-file)))
  (when (path/file? (zed-desired-file))
    (success "managed Zed extension manifest exists")
    (let [desired (desired-zed-extensions)
          installed (installed-zed-extensions)
          missing (missing-items desired installed)
          extra (missing-items installed desired)]
      (if (empty? missing)
        (success "desired Zed extensions are installed")
        (do
          (set ok false)
          (failure "desired Zed extensions are installed" (print-lines missing))))
      (if (empty? extra)
        (success "no unmanaged Zed extensions installed")
        (warning "unmanaged Zed extensions installed" (print-lines extra)))))
  (if ok
    (echo :check "zed doctor passed")
    (exit 1)))

(defcmd doctor [_ subcmd & args &opts profile? --profile quiet? --quiet verbose-opt? --verbose strict? --strict]
  (setdyn :doctor-verbose verbose-opt?)
  (setdyn :doctor-strict strict?)
  (when (and quiet? verbose-opt?)
    (abort usage))
  (when (and profile? (not (= subcmd "shell")))
    (abort "Usage: hey doctor shell [--profile]"))
  (when (and strict? (not (or (nil? subcmd) (= subcmd "secrets"))))
    (abort "Usage: hey doctor [secrets] --strict"))
  (when (and (= subcmd "fix") (not (= 1 (length args))))
    (abort usage))
  (when (and (not (= subcmd "fix")) (not (empty? args)))
    (abort usage))
  (case* subcmd
    nil (doctor-all)
    "agents" (doctor-agents)
    "env" (doctor-env)
    "fix" (doctor-fix (first args))
    "nix" (doctor-nix)
    "secrets" (doctor-secrets)
    "shell" (doctor-shell profile?)
    "sync" (doctor-sync)
    "zed" (doctor-zed)
    (abort usage)))
