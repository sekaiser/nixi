#!/usr/bin/env janet
# Run project-local development workflows.
#
# SYNOPSIS:
#   project doctor
#   project status
#   project shell
#   project check
#   project test
#   project ci
#   project up [PROCESS...]
#   project down
#   project logs [PROCESS]
#   project watch
#   project profile
#   project disk
#   project git
#   project clean [--yes]
#
# SUBCOMMANDS:
#   doctor   Check project language, tools, direnv, and Codegraph readiness.
#   status   Print detected project root, language, and git state.
#   shell    Enter the project Nix development shell.
#   check    Run the project's fast validation command.
#   test     Run the project's test command.
#   ci       Run the project CI entrypoint.
#   up       Start project-local services through process-compose.
#   down     Stop project-local services through process-compose.
#   logs     Show project-local service logs through process-compose.
#   watch    Re-run the fast validation command with watchexec.
#   profile  Run a language-appropriate profiling/benchmark helper.
#   disk     Show common project disk usage hotspots.
#   git      Show branch, working tree, and worktree state.
#   clean    Remove common build output, only with --yes.

(use hey)
(use hey/cmd)
(import hey/process)

(def- usage
  "Usage: hey project doctor|status|shell|check|test|ci|up|down|logs|services|watch|profile|disk|git|clean [ARGS...] [--yes]")

(def- run process/capture)

(defn- shell-output [script]
  ((run @["sh" "-c" script]) :out))

(defn- command? [name]
  (truthy? (path/find name)))

(def- run-command process/run!)

(def- process-compose-files ["process-compose.yaml" "process-compose.yml"])
(def- project-files
  ["justfile" "flake.nix" "Cargo.toml" "go.mod" "pom.xml"
   "build.gradle" "build.gradle.kts" "gradlew" "package.json" "pyproject.toml"
   ".envrc" ;process-compose-files])

(defn- git-root []
  (let [result (run @["git" "rev-parse" "--show-toplevel"])]
    (when (= 0 (result :status))
      (os/realpath (string/trim (result :out))))))

(defn- exists-in? [root file]
  (path/exists? (path/join root file)))

(defn- project-root []
  (var current (os/cwd))
  (var root nil)
  (let [boundary (git-root)]
    (while (not root)
      (cond
        (or (= current boundary) (some |(exists-in? current $) project-files))
        (set root current)
        (= current "/") (set root (os/cwd))
        # Canonical paths keep Git's boundary comparable after each ascent.
        (set current (os/realpath (path/join current "..")))))
    root))

(defn- first-existing [root files]
  (find |(exists-in? root $) files))

(defn- project-state-dir [root]
  (path/join root ".nixi"))

(defn- process-compose-file [root]
  (first-existing root process-compose-files))

(defn- process-compose-socket [root]
  (path/join (project-state-dir root) "process-compose.sock"))

(defn- project-language [root]
  (cond
    (exists-in? root "Cargo.toml") "rust"
    (exists-in? root "go.mod") "go"
    (or (exists-in? root "pom.xml")
        (exists-in? root "build.gradle")
        (exists-in? root "build.gradle.kts")
        (exists-in? root "gradlew")) "java"
    "generic"))

(defn- gradle-command [root subcmd]
  (if (path/file? (path/join root "gradlew"))
    @["./gradlew" subcmd]
    @["gradle" subcmd]))

(defn- just-command? [root name]
  (when (exists-in? root "justfile")
    (unless (command? "just")
      (abort "Project has a justfile, but just is not available"))
    (let [result (run @["just" "--justfile" (path/join root "justfile") "--summary"])]
      (unless (= 0 (result :status))
        (abort "Could not read project recipes: %s" (result :err)))
      (truthy? (index-of name (string/split " " (result :out)))))))

(defn- project-command [kind lang root]
  (when (just-command? root kind)
    (break @["just" "--justfile" (path/join root "justfile") kind]))
  (when (and (= kind "check") (exists-in? root "flake.nix"))
    (break @["nix" "flake" "check"]))
  (case kind
    "check" (case lang
              "rust" @["cargo" "check" "--all-targets" "--all-features"]
              "go" @["go" "test" "./..."]
              "java" (if (exists-in? root "pom.xml")
                       @["mvn" "test"]
                       (gradle-command root "test"))
              (abort "No project %s command configured; add a justfile recipe or flake checks" kind))
    "test" (case lang
             "rust" (if (command? "cargo-nextest")
                      @["cargo" "nextest" "run"]
                      @["cargo" "test"])
             "go" (if (command? "gotestsum")
                    @["gotestsum" "--format" "testname" "--" "./..."]
                    @["go" "test" "./..."])
             "java" (if (exists-in? root "pom.xml")
                      @["mvn" "test"]
                      (gradle-command root "test"))
             (abort "No project %s command configured; add a justfile test recipe" kind))
    "profile" (case lang
                "rust" (if (command? "samply")
                         @["samply" "record" "cargo" "test"]
                         @["hyperfine" "cargo check"])
                "go" @["go" "test" "-bench=." "./..."]
                "java" (if (exists-in? root "pom.xml")
                         @["mvn" "test"]
                         (gradle-command root "test"))
                (abort "No project %s command configured; add a justfile recipe" kind))))

(defn- print-tool [name]
  (if (command? name)
    (echof :check "%s command is available" name)
    (echof :warn "%s command is missing" name)))

(defn- project-status []
  (let [root (project-root)
        lang (project-language root)]
    (echof "root: %s" root)
    (echof "language: %s" lang)
    (when (exists-in? root "flake.nix")
      (echof "flake: %s" (path/join root "flake.nix")))
    (when-let [pc (process-compose-file root)]
      (echof "process-compose: %s" (path/join root pc)))
    (when (exists-in? root "justfile")
      (echof "justfile: %s" (path/join root "justfile")))
    (when (exists-in? root ".envrc")
      (echof "direnv: %s" (or (os/getenv "DIRENV_FILE") "<not loaded in this shell>")))
    (when (exists-in? root ".codegraph")
      (echof "codegraph: %s" (path/join root ".codegraph")))
    (when (exists-in? root ".git")
      (let [status (shell-output "git status --short | wc -l | tr -d ' '")]
        (echof "git changed files: %s" (if (empty? status) "0" status))))))

(defn- project-git []
  (let [root (project-root)]
    (os/cd root)
    (run-command @["git" "status" "--short" "--branch"])
    (run-command @["git" "worktree" "list"])))

(defn- project-doctor []
  (let [root (project-root)
        lang (project-language root)
        required @["git"]]
    (when (exists-in? root "flake.nix") (array/push required "nix"))
    (when (exists-in? root "justfile") (array/push required "just"))
    (when (exists-in? root ".envrc") (array/push required "direnv"))
    (when (process-compose-file root) (array/push required "process-compose"))
    (case lang
      "rust" (array/push required "cargo")
      "go" (array/push required "go")
      "java" (do
               (array/push required "java")
               (cond (exists-in? root "pom.xml") (array/push required "mvn")
                     (not (exists-in? root "gradlew")) (array/push required "gradle"))))
    (project-status)
    (print-tool "git")
    (when (exists-in? root ".envrc")
      (print-tool "direnv"))
    (when (exists-in? root "flake.nix")
      (print-tool "nix"))
    (when (exists-in? root "justfile")
      (print-tool "just"))
    (when (process-compose-file root)
      (print-tool "process-compose"))
    (case lang
      "rust" (do
               (print-tool "cargo")
               (print-tool "rust-analyzer")
               (print-tool "cargo-nextest")
               (print-tool "bacon")
               (print-tool "cargo-deny")
               (print-tool "cargo-mutants"))
      "go" (do
             (print-tool "go")
             (print-tool "gopls")
             (print-tool "golangci-lint")
             (print-tool "gotestsum"))
      "java" (do
               (print-tool "java")
               (print-tool "mvn")
               (print-tool "gradle")
               (print-tool "jdtls")))
    (when (exists-in? root ".codegraph")
      (print-tool "codegraph")
      (when (command? "codegraph")
        (run-command @["codegraph" "status" root])))
    (let [missing (filter |(not (command? $)) required)]
      (unless (empty? missing)
        (abort "Project requirements missing: %s" (string/join missing ", "))))
    (echof :check "project doctor complete")))

(defn- project-shell []
  (let [root (project-root)]
    (os/cd root)
    (cond
      (exists-in? root "flake.nix") (run-command @["nix" "develop"])
      (exists-in? root ".envrc") (run-command @["direnv" "exec" root (or (os/getenv "SHELL") "zsh")])
      (abort "No project shell found. Add flake.nix or .envrc."))))

(defn- project-run [kind]
  (let [root (project-root)
        lang (project-language root)
        cmd (project-command kind lang root)]
    (os/cd root)
    (run-command cmd)))

(defn- project-ci []
  (let [root (project-root)]
    (os/cd root)
    (cond
      (just-command? root "ci") (run-command @["just" "ci"])
      (exists-in? root "flake.nix") (run-command @["nix" "flake" "check"])
      (do
        (project-run "check")
        (project-run "test")))))

(defn- process-compose-base [root]
  (unless (or (dryrun?) (command? "process-compose"))
    (abort "process-compose is not available"))
  (if-let [config-file (process-compose-file root)]
    (do
      (unless (dryrun?) (path/mkdirp (project-state-dir root)))
      @["process-compose"
        "--use-uds"
        "--unix-socket" (process-compose-socket root)
        "--config" (path/join root config-file)])
    (abort "No process-compose.yaml or process-compose.yml found")))

(defn- process-compose-client [root]
  (unless (or (dryrun?) (command? "process-compose"))
    (abort "process-compose is not available"))
  @["process-compose"
    "--use-uds"
    "--unix-socket" (process-compose-socket root)])

(defn- project-up [processes]
  (let [root (project-root)
        cmd (process-compose-base root)]
    (os/cd root)
    (array/push cmd "up")
    (array/concat cmd processes)
    (run-command cmd)))

(defn- project-down []
  (let [root (project-root)
        cmd (process-compose-client root)]
    (os/cd root)
    (array/push cmd "down")
    (run-command cmd)))

(defn- project-logs [process]
  (let [root (project-root)
        cmd (process-compose-client root)]
    (os/cd root)
    (array/concat cmd @["process" "logs"])
    (when process
      (array/push cmd process))
    (run-command cmd)))

(defn- project-services-status []
  (let [root (project-root)
        cmd (process-compose-client root)]
    (os/cd root)
    (array/push cmd "list")
    (run-command cmd)))

(defn- project-watch []
  (let [root (project-root)
        lang (project-language root)
        cmd (project-command "check" lang root)]
    (os/cd root)
    (process/watch! root nil cmd)))

(defn- project-disk []
  (let [root (project-root)]
    (os/cd root)
    (run-command @["sh" "-c" "du -sh . .git .codegraph target node_modules 2>/dev/null | sort -h"])))

(defn- clean-targets [root]
  (filter |(path/exists? $)
          @[(path/join root "target")
            (path/join root "node_modules")
            (path/join root ".next")
            (path/join root "dist")
            (path/join root "build")]))

(defn- project-clean [yes?]
  (let [root (project-root)
        targets (clean-targets root)]
    (if (empty? targets)
      (echof :check "no project build output found")
      (do
        # Validate the complete removal plan before deleting anything.
        (when (and yes? (not (dryrun?)))
          (each target targets
            (let [tracked (run @["git" "-C" root "ls-files" "--" target])]
              (unless (= 0 (tracked :status))
                (abort "Could not verify tracked files; refusing cleanup: %s" (tracked :err)))
              (unless (empty? (tracked :out))
                (abort "Refusing to remove tracked project files in %s" target)))))
        (each target targets
          (if (or (dryrun?) (not yes?))
            (echof "DRYRUN: git -C %s clean -fdx -- %s" root target)
            (do
              # A single -f deliberately preserves nested repositories and
              # worktrees, including those hidden inside ignored directories.
              (run-command @["git" "-C" root "clean" "-fdx" "--" target]))))
        (unless (or yes? (dryrun?))
          (echof :warn "rerun with --yes to remove these directories"))))))

(defcmd project [_ subcmd & args &opts yes? --yes]
  (case subcmd
    "doctor" (if (empty? args) (project-doctor) (abort usage))
    "status" (if (empty? args) (project-status) (abort usage))
    "shell" (if (empty? args) (project-shell) (abort usage))
    "check" (if (empty? args) (project-run "check") (abort usage))
    "test" (if (empty? args) (project-run "test") (abort usage))
    "ci" (if (empty? args) (project-ci) (abort usage))
    "up" (project-up args)
    "down" (if (empty? args) (project-down) (abort usage))
    "logs" (if (< (length args) 2) (project-logs (get args 0)) (abort usage))
    "services" (if (empty? args) (project-services-status) (abort usage))
    "watch" (if (empty? args) (project-watch) (abort usage))
    "profile" (if (empty? args) (project-run "profile") (abort usage))
    "disk" (if (empty? args) (project-disk) (abort usage))
    "git" (if (empty? args) (project-git) (abort usage))
    "clean" (if (empty? args) (project-clean yes?) (abort usage))
    (abort usage)))
