(use hey)
(import hey/process)
(use ./support)

(use hey/cmd)

(def- usage "Usage: hey check ")

(defn- check-help-pages [hey-bin]
  (let [commands (->> (path/files-in (path :bin "hey.d"))
                      (keep |(path/no-ext $ ".janet"))
                      (map path/basename)
                      (sort))]
    (var ok true)
    (each command commands
      (unless (check-command (string command " help renders") @[hey-bin "-h" command])
        (set ok false)))
    ok))

(defn- manifest-key-name [key]
  (let [value (string key)]
    (if (string/has-prefix? ":" value)
      (slice value 1)
      value)))

(defn- check-command-manifest []
  (let [manifest (flake/commands)]
    (if (empty? manifest)
      (do
        (echof :warn "generated command manifest is not installed yet")
        true)
      (let [declared (sort (map manifest-key-name (keys manifest)))
            runtime (command-names)
            missing-runtime (filter |(not (index-of $ runtime)) declared)
            missing-manifest (filter |(not (index-of $ declared)) runtime)]
        (cond
          (not (empty? missing-runtime))
          (do
            (echof :error "command manifest declares unknown commands: %s" (string/join missing-runtime ", "))
            false)

          (not (empty? missing-manifest))
          (do
            (echof :error "command manifest missing runtime commands: %s" (string/join missing-manifest ", "))
            false)

          (do
            (echof :check "command manifest matches runtime commands")
            true))))))

(defn run []
  (let [test-root (process/temporary-directory "hey-check-cli")
        cleanup (trap (fn [&] (path/rmtree test-root)) :exit)
        hey-bin (path :bin "hey")
        host-fixture (path :framework "checks/fixtures/cli-host")
        doctor-env-prefix @["env" "-u" "HEYENV" "-u" "DOTFILES"
                            (string "DOTFILES_HOME=" host-fixture)
                            "HEY_HOST=laptop" "HEY_USER=alice" "HEY_THEME=alucard"]
        data-home (string "" test-root "/hey-check-data")
        runtime-home (string "" test-root "/hey-check-runtime")
        profile-state-home (string test-root "/hey-check-profile-state")
        profile-env-prefix @["env" (string "XDG_STATE_HOME=" profile-state-home)
                             (string "XDG_RUNTIME_DIR=" runtime-home)]
        secret-fixture (string "" test-root "/hey-check-secret-fixture")
        ssh-fixture-home (string "" test-root "/hey-check-ssh-home")
        capability-fixture-home (string "" test-root "/hey-check-capability-data")
        project-fixture (string "" test-root "/hey-check-project-fixture")
        template-target (string "" test-root "/hey-check-template-target")
        template-nonempty (string "" test-root "/hey-check-template-nonempty")
        commands @[
          ["main help" @[hey-bin "-h"]]
          ["help alias" @[hey-bin "h" "vars"]]
          ["hey completion syntax" @["zsh" "-n" (path :config "zsh/completions/_hey")]]
          ["tmux helper syntax" @["zsh" "-n"
                                  (path :config "tmux/bin/status-right.zsh")
                                  (path :config "tmux/bin/status-action.zsh")
                                  (path :config "tmux/bin/swap-pane.zsh")]]
          ["zsh rc syntax" @["zsh" "-n" (path :config "zsh/.zshrc")]]
          ["zsh prompt syntax" @["zsh" "-n" (path :themes "alucard/config/zsh/prompt.zsh")]]
          ["eks list dry-run" @["env" (string "XDG_CONFIG_HOME=" test-root "/hey-eks-check") hey-bin "-!" "eks" "list"]]
          ["eks login dry-run" @["env" (string "XDG_CONFIG_HOME=" test-root "/hey-eks-check") hey-bin "-!" "eks" "login" "remoteprofile"]]
          ["eks kubeconfig dry-run" @["env" (string "XDG_CONFIG_HOME=" test-root "/hey-eks-check") hey-bin "-!" "eks" "kubeconfig" "remote-dev"]]
          ["eks use inferred bastion dry-run" @["env" (string "XDG_CONFIG_HOME=" test-root "/hey-eks-check") hey-bin "-!" "eks" "use" "remote-dev"]]
          ["eks open inferred bastion dry-run" @["env" (string "XDG_CONFIG_HOME=" test-root "/hey-eks-check") hey-bin "-!" "eks" "open" "remote-dev"]]
          ["eks logs inferred bastion dry-run" @["env" (string "XDG_CONFIG_HOME=" test-root "/hey-eks-check") hey-bin "-!" "eks" "logs" "remote-dev" "api" "default"]]
          ["eks port-forward inferred bastion dry-run" @["env" (string "XDG_CONFIG_HOME=" test-root "/hey-eks-check") hey-bin "-!" "eks" "port-forward" "remote-dev" "svc/api" "8080:80" "default"]]
          ["eks shell inferred bastion dry-run" @["env" (string "XDG_CONFIG_HOME=" test-root "/hey-eks-check") hey-bin "-!" "eks" "shell" "remote-dev"]]
          ["eks status inferred bastion dry-run" @["env" (string "XDG_CONFIG_HOME=" test-root "/hey-eks-check") hey-bin "-!" "eks" "status" "remote-dev"]]
          ["eks credentials inferred bastion dry-run" @["env" (string "XDG_CONFIG_HOME=" test-root "/hey-eks-check") hey-bin "-!" "eks" "credentials" "remote-dev"]]
          ["eks env inferred bastion dry-run" @["env" (string "XDG_CONFIG_HOME=" test-root "/hey-eks-check") hey-bin "-!" "eks" "env" "remote-dev"]]
          ["eks doctor inferred bastion dry-run" @["env" (string "XDG_CONFIG_HOME=" test-root "/hey-eks-check") hey-bin "-!" "eks" "doctor" "remote-dev"]]
          ["eks vpn status inferred bastion dry-run" @["env" (string "XDG_CONFIG_HOME=" test-root "/hey-eks-check") hey-bin "-!" "eks" "vpn" "status" "remote-dev"]]
          ["eks vpn start inferred bastion dry-run" @["env" (string "XDG_CONFIG_HOME=" test-root "/hey-eks-check") hey-bin "-!" "eks" "vpn" "start" "remote-dev"]]
          ["eks bastion open dry-run" @["env" (string "XDG_CONFIG_HOME=" test-root "/hey-eks-check") hey-bin "-!" "eks" "--bastion" "eks-bastion" "open" "remote-dev"]]
          ["eks bastion login dry-run" @["env" (string "XDG_CONFIG_HOME=" test-root "/hey-eks-check") hey-bin "-!" "eks" "--bastion" "eks-bastion" "login" "remoteprofile"]]
          ["eks local open dry-run" @["env" (string "XDG_CONFIG_HOME=" test-root "/hey-eks-check") hey-bin "-!" "eks" "open" "local-dev"]]
          ["eks local logs dry-run" @["env" (string "XDG_CONFIG_HOME=" test-root "/hey-eks-check") hey-bin "-!" "eks" "logs" "local-dev" "api"]]
          ["eks local port-forward dry-run" @["env" (string "XDG_CONFIG_HOME=" test-root "/hey-eks-check") hey-bin "-!" "eks" "port-forward" "local-dev" "svc/api" "8080:80"]]
          ["eks local open all dry-run" @["env" (string "XDG_CONFIG_HOME=" test-root "/hey-eks-check") hey-bin "-!" "eks" "open" "local-dev" "all"]]
          ["eks local open custom namespace dry-run" @["env" (string "XDG_CONFIG_HOME=" test-root "/hey-eks-check") hey-bin "-!" "eks" "open" "local-dev" "custom-ns"]]
          ["build alias dry-run" @[hey-bin "b" "-!"]]
          ["clean dry-run" @[hey-bin "-!" "clean"]]
          ["clean zsh dry-run" @[hey-bin "-!" "clean" "zsh"]]
          ["context" @[hey-bin "context"]]
          ["context alias" @[hey-bin "ctx"]]
          ["doctor daily dry-run" @[hey-bin "-!" "doctor"]]
          ["doctor agents dry-run" @[hey-bin "-!" "doctor" "agents"]]
          ["doctor fix stale paths dry-run" @[hey-bin "-!" "doctor" "fix" "stale-store-paths"]]
          ["doctor fix tmux env dry-run" @[hey-bin "-!" "doctor" "fix" "tmux-env"]]
          ["doctor fix zsh cache dry-run" @[hey-bin "-!" "doctor" "fix" "zsh-cache"]]
          ["doctor env" @[;doctor-env-prefix hey-bin "doctor" "env"]]
          ["doctor nix dry-run" @[hey-bin "-!" "doctor" "nix"]]
          ["doctor shell dry-run" @[hey-bin "-!" "doctor" "shell"]]
          ["doctor shell profile dry-run" @[hey-bin "-!" "doctor" "shell" "--profile"]]
          ["doctor secrets dry-run" @[hey-bin "-!" "doctor" "secrets"]]
          ["doctor sync dry-run" @[hey-bin "-!" "doctor" "sync"]]
          ["doctor zed dry-run" @[hey-bin "-!" "doctor" "zed"]]
          ["direnv doctor dry-run" @[hey-bin "-!" "direnv" "doctor"]]
          ["direnv reload dry-run" @[hey-bin "-!" "direnv" "reload"]]
          ["direnv status dry-run" @[hey-bin "-!" "direnv" "status"]]
          ["dev doctor dry-run" @[hey-bin "-!" "dev" "doctor"]]
          ["dev status dry-run" @[hey-bin "-!" "dev" "status"]]
          ["dev tools" @[hey-bin "dev" "tools"]]
          ["dev shell dry-run" @[hey-bin "-!" "dev" "shell"]]
          ["dev check dry-run" @[hey-bin "-!" "dev" "check"]]
          ["dev test dry-run" @["sh" "-c" (string "cd " project-fixture " && " hey-bin " -! dev test")]]
          ["dev ci dry-run" @[hey-bin "-!" "dev" "ci"]]
          ["dev watch dry-run" @[hey-bin "-!" "dev" "watch"]]
          ["dev profile dry-run" @[hey-bin "-!" "dev" "profile"]]
          ["dev disk dry-run" @[hey-bin "-!" "dev" "disk"]]
          ["dev git dry-run" @[hey-bin "-!" "dev" "git"]]
          ["dev clean dry-run" @[hey-bin "-!" "dev" "clean"]]
          ["project doctor dry-run" @[hey-bin "-!" "project" "doctor"]]
          ["project shell dry-run" @[hey-bin "-!" "project" "shell"]]
          ["project check dry-run" @[hey-bin "-!" "project" "check"]]
          ["project test dry-run" @["sh" "-c" (string "cd " project-fixture " && " hey-bin " -! project test")]]
          ["project ci dry-run" @[hey-bin "-!" "project" "ci"]]
          ["project watch dry-run" @[hey-bin "-!" "project" "watch"]]
          ["project disk dry-run" @[hey-bin "-!" "project" "disk"]]
          ["project git dry-run" @[hey-bin "-!" "project" "git"]]
          ["project clean dry-run" @[hey-bin "-!" "project" "clean"]]
          ["project up dry-run" @["sh" "-c" (string "cd " project-fixture " && " hey-bin " -! project up db")]]
          ["project down dry-run" @["sh" "-c" (string "cd " project-fixture " && " hey-bin " -! project down")]]
          ["project logs dry-run" @["sh" "-c" (string "cd " project-fixture " && " hey-bin " -! project logs db")]]
          ["project services dry-run" @["sh" "-c" (string "cd " project-fixture " && " hey-bin " -! project services")]]
          ["check flake dry-run" @[hey-bin "-!" "check" "flake"]]
          ["check eval host dry-run" @[hey-bin "-!" "check" "eval" "vm-a"]]
          ["check external flake dry-run" @[hey-bin "-!" "check" "--flake" "/tmp/site" "flake"]]
          ["check external eval host dry-run" @[hey-bin "-!" "check" "--flake" "/tmp/site" "eval" "vm-a"]]
          ["check external build dry-run" @[hey-bin "-!" "check" "--flake" "/tmp/site" "build" "vm-a"]]
          ["sync dry-run" @["env" (string "XDG_DATA_HOME=" data-home) hey-bin "-!" "sync"]]
          ["sync explain" @["env" (string "XDG_DATA_HOME=" data-home) hey-bin "sync" "--explain"]]
          ["sync build explain" @["env" (string "XDG_DATA_HOME=" data-home) hey-bin "sync" "--explain" "build"]]
          ["sync external host explain" @["env" (string "XDG_DATA_HOME=" data-home) hey-bin "sync" "--explain" "--flake" "/tmp/site" "--host" "vm-a"]]
          ["sync external flake-host explain" @["env" (string "XDG_DATA_HOME=" data-home) hey-bin "sync" "--explain" "--flake" "/tmp/site#vm-a"]]
          ["sync local flake-host explain" @["env" (string "XDG_DATA_HOME=" data-home) hey-bin "sync" "--explain" "--flake" ".#vm-a"]]
          ["sync alias dry-run" @["env" (string "XDG_RUNTIME_DIR=" runtime-home) (string "XDG_DATA_HOME=" data-home) hey-bin "s" "-!"]]
          ["sync build dry-run" @["env" (string "XDG_DATA_HOME=" data-home) hey-bin "-!" "sync" "build"]]
          ["hook dry-run" @["env" (string "XDG_RUNTIME_DIR=" runtime-home) (string "XDG_DATA_HOME=" data-home) hey-bin "-!" "hook" "reload" "-f"]]
          ["reload dry-run" @["env" "-u" "XDG_CURRENT_DESKTOP" (string "XDG_RUNTIME_DIR=" runtime-home) (string "XDG_DATA_HOME=" data-home) hey-bin "-!" "reload"]]
          ["reload cache dry-run" @[hey-bin "-!" "reload" "cache"]]
          ["reload direnv dry-run" @[hey-bin "-!" "reload" "direnv"]]
          ["reload k9s dry-run" @[hey-bin "-!" "reload" "k9s"]]
          ["reload tmux dry-run" @[hey-bin "-!" "reload" "tmux"]]
          ["reload zsh dry-run" @["env" (string "XDG_RUNTIME_DIR=" runtime-home) (string "XDG_DATA_HOME=" data-home) hey-bin "-!" "reload" "zsh"]]
          ["repl dry-run" @[hey-bin "-!" "repl"]]
          ["search dry-run" @[hey-bin "-!" "search" "ripgrep"]]
          ["search from dry-run" @[hey-bin "-!" "search" "--from" "nixpkgs#gnome3" "vala"]]
          ["ssh doctor dry-run" @[hey-bin "-!" "ssh" "doctor"]]
          ["ssh ps dry-run" @[hey-bin "-!" "ssh" "ps"]]
          ["build dry-run" @["env" (string "XDG_DATA_HOME=" data-home) hey-bin "-!" "build"]]
          ["build all dry-run" @["env" (string "XDG_DATA_HOME=" data-home) hey-bin "-!" "build" "-a"]]
          ["build iso dry-run" @["env" (string "XDG_DATA_HOME=" data-home) hey-bin "-!" "build" "iso"]]
          ["build vm dry-run" @["env" (string "XDG_DATA_HOME=" data-home) hey-bin "-!" "build" "vm" "--option" "max-jobs" "0"]]
          ["vars ls" @["env" (string "XDG_RUNTIME_DIR=" runtime-home) (string "XDG_DATA_HOME=" data-home) hey-bin "vars" "ls"]]
          ["vars set alias" @["env" (string "XDG_RUNTIME_DIR=" runtime-home) (string "XDG_DATA_HOME=" data-home) hey-bin "set" "hey-check-key" "hey-check-value"]]
          ["vars get alias" @["env" (string "XDG_RUNTIME_DIR=" runtime-home) (string "XDG_DATA_HOME=" data-home) hey-bin "get" "hey-check-key"]]
          ["swap list fresh" @["env" (string "XDG_DATA_HOME=" test-root "/hey-check-swap-data") hey-bin "swap" "--list"]]
          ["watch eval dry-run" @[hey-bin "-!" "watch" "eval"]]
          ["watch eval host dry-run" @[hey-bin "-!" "watch" "eval" "vm-a"]]
          ["watch cli dry-run" @[hey-bin "-!" "watch" "cli"]]
          ["watch flake dry-run" @[hey-bin "-!" "watch" "flake"]]
          ["watch external flake dry-run" @[hey-bin "-!" "watch" "flake" "--flake" "/tmp/site"]]
          ["watch external eval host dry-run" @[hey-bin "-!" "watch" "eval" "vm-a" "--flake" "/tmp/site"]]
          ["watch tmux dry-run" @[hey-bin "-!" "watch" "tmux"]]
          ["watch utm-cli dry-run" @[hey-bin "-!" "watch" "utm-cli"]]
          ["watch run dry-run" @[hey-bin "-!" "watch" "run" "hey" "tmux" "doctor"]]
          ["tmux clean dry-run" @[hey-bin "-!" "tmux" "clean"]]
          ["tmux project dry-run" @[hey-bin "-!" "tmux" "project" "nixi" (path :home)]]
          ["tmux sessions dry-run" @[hey-bin "-!" "tmux" "sessions"]]
          ["tmux swap-pane dry-run" @[hey-bin "-!" "tmux" "swap-pane" "left"]]
          ["template init dry-run" @[hey-bin "-!" "template" "init" "rust" "/tmp/hey-rust-template"]]
          ["host doctor dry-run" @[hey-bin "-!" "host" "doctor" "eks-bastion"]]
          ["host explain dry-run" @[hey-bin "-!" "host" "explain" "laptop" "--flake" host-fixture]]
          ["host list dry-run" @[hey-bin "-!" "host" "list"]]
          ["host list external dry-run" @[hey-bin "-!" "host" "list" "--flake" "/tmp/site"]]
          ["image list dry-run" @[hey-bin "-!" "image" "list" "utm"]]
          ["image build dry-run" @[hey-bin "-!" "image" "build" "utm"]]
          ["image list external dry-run" @[hey-bin "-!" "image" "list" "utm" "--flake" "/tmp/site"]]
          ["image build external dry-run" @[hey-bin "-!" "image" "build" "utm" "--flake" "/tmp/site"]]
          ["info local ip dry-run" @[hey-bin "-!" "info" "ip"]]
          ["info wan ip dry-run" @[hey-bin "-!" "info" "ip" "-w"]]
          ["path config" @[hey-bin "path" "-d" "config"]]
          ["path themes" @[hey-bin "path" "-d" "themes"]]
          ["path theme" @[hey-bin "path" "-d" "theme"]]
          ["path xdg config" @[hey-bin "path" "-d" "xdg" "config"]]
          ["path file predicate" @[hey-bin "path" "-f" "bin" "hey"]]
          ["pull targeted dry-run" @[hey-bin "-!" "pull" "nixpkgs"]]
          ["pull override dry-run" @[hey-bin "-!" "pull" "-o" "nixpkgs=github:NixOS/nixpkgs"]]
          ["profile system path" @[hey-bin "profile"]]
          ["profile user ls" @[;profile-env-prefix hey-bin "profile" "ls" "-u"]]
          ["profile user current" @[;profile-env-prefix hey-bin "profile" "current" "-u"]]
          ["profile user previous" @[;profile-env-prefix hey-bin "profile" "previous" "-u"]]
          ["profile user rollback dry-run" @[;profile-env-prefix hey-bin "-!" "profile" "rollback" "-u"]]
          ["profile user diff dry-run" @[;profile-env-prefix hey-bin "-!" "profile" "diff" "-u"]]
          ["asset command dispatch" @[hey-bin "which" "@tmux" "swap-pane" "left"]]]
        help-commands @[
          ["main help wording" @[hey-bin "-h"] "Build flake artifacts or recompile bin/hey" "Run local validation suites" "Display paths inside this flake and XDG areas" "Manage UTM-backed NixOS VMs"]
          ["check help" @[hey-bin "-h" "check"] "check eval [HOST] [--flake FLAKE]" "check all [HOST]"]
          ["clean help" @[hey-bin "-h" "clean"] "clean [all|zsh|nix|k9s|cache]"]
          ["context help" @[hey-bin "-h" "context"] "context"]
          ["dev help" @[hey-bin "-h" "dev"] "dev doctor" "dev clean [--yes]"]
          ["gc help" @[hey-bin "-h" "gc"] "gc [-a|--all] [-s|--system] [-d]"]
          ["build help" @[hey-bin "-h" "build"] "build vm [ARGS...]" "vm-with-bootloader"]
          ["host help" @[hey-bin "-h" "host"] "host doctor HOST [--flake FLAKE]" "host explain HOST [--flake FLAKE]" "host list [--flake FLAKE]"]
          ["image help" @[hey-bin "-h" "image"] "image list HOST [--flake FLAKE]" "image build HOST [VARIANT] [--flake FLAKE]"]
          ["info help" @[hey-bin "-h" "info"] "info [-r] ip [-w]"]
          ["path help" @[hey-bin "-h" "path"] "path [-e|-d|-f] [-a] [AREA] [SEGMENTS...]"]
          ["project help" @[hey-bin "-h" "project"] "project doctor" "project clean [--yes]"]
          ["profile help" @[hey-bin "-h" "profile"] "profile current [-u|--user]" "profile rollback [GEN] [-u|--user]" "profile diff [FROM] [TO] [-u|--user]" "hey profile rm -1"]
          ["repl help" @[hey-bin "-h" "repl"] "repl [-j|-d] [ARGS...]"]
          ["reload help" @[hey-bin "-h" "reload"] "reload [all|tmux|zsh|direnv|k9s|cache]"]
          ["search help" @[hey-bin "-h" "search"] "SYNOPSIS:" "hey search" "nixpkgs#gnome3"]
          ["ssh help" @[hey-bin "-h" "ssh"] "ssh ps" "Detect SSH tunnels"]
          ["swap help" @[hey-bin "-h" "swap"] "-l, --list"]
          ["template help" @[hey-bin "-h" "template"] "template list" "template init NAME [DIR]"]
          ["vars help" @[hey-bin "-h" "vars"] "vars [ls]" "vars set KEY VALUE"]
          ["sync help" @[hey-bin "-h" "sync"] "sync [--fast] [--explain] [--flake FLAKE] [--host HOST] [COMMAND...]" "sync rollback GENERATION" "sync --rollback"]
          ["utm help" @[hey-bin "-h" "utm"] "utm create-image --vm VM --flake FLAKE#HOST" "utm update VM [--flake FLAKE#HOST]" "utm diff VM [--flake FLAKE#HOST]"]
          ["watch help" @[hey-bin "-h" "watch"] "watch eval [HOST] [--flake FLAKE]" "watch flake [--flake FLAKE]" "checked package sources" "watch run COMMAND [ARGS...]"]
          ["hey completion command coverage" @["sed" "-n" "1,$p" (path :config "zsh/completions/_hey")]
           "host) __hey_host"
           "image) __hey_image"
           "template) __hey_template"
           "--flake[Target flake, optionally including #HOST]"
           "--host[Target host from selected flake]"
           "function __hey_manifest_command_entries"
           "function __hey_refresh_manifest_cache"
           "function __hey_complete_manifest_subcommands"
           "function __hey_dev"
           "function __hey_host"
           "function __hey_image"
           "function __hey_project"
           "function __hey_template"
           "function __hey_watch"]
          ["zsh completion avoids unknown-command autosuggestions"
           @["sed" "-n" "1,20p" (path :config "zsh/completion.zsh")]
           "ZSH_AUTOSUGGEST_COMPLETION_IGNORE='[^[:space:]]#'"]
          ["framework hey help includes ssh" @[hey-bin "-h"] "ssh        -- Inspect local SSH process and tunnel state"]
          ["framework hey eks help includes port-forward" @[hey-bin "-h" "eks"] "eks port-forward CLUSTER RESOURCE LOCAL:REMOTE [default|NAMESPACE]"]
          ["path home output" @[hey-bin "path" "home"] (path :home)]
          ["path immutable flake fallback output"
           @["env"
             "-u" "DOTFILES"
             "-u" "DOTFILES_HOME"
             "-u" "HEYENV"
             (string "HOME=" test-root "/hey-missing-home")
             (string "HEY_FLAKE_ROOT=" test-root "/hey-flake-root")
             hey-bin "path" "home"]
           (string "" test-root "/hey-flake-root")]
          ["path framework output" @[hey-bin "path" "framework"] (path :framework)]
          ["path bin output" @[hey-bin "path" "bin"] (path :bin)]
          ["path hosts output" @[hey-bin "path" "hosts"] (path :hosts)]
          ["sync explain output" @["env" (string "XDG_DATA_HOME=" data-home) hey-bin "sync" "--explain"] "activation command:" "build target:"]
          ["sync build explain output" @["env" (string "XDG_DATA_HOME=" data-home) hey-bin "sync" "--explain" "build"] "build command:" "--no-link"]
          ["sync external flake output" @["env" (string "XDG_DATA_HOME=" data-home) hey-bin "sync" "--explain" "--flake" "/tmp/site#vm-a"] "flake: /tmp/site#vm-a" "DOTFILES: /tmp/site"]
          ["sync local flake output" @["env" (string "XDG_DATA_HOME=" data-home) hey-bin "sync" "--explain" "--flake" ".#vm-a"] (string "flake: " (path :home) "#vm-a") (string "DOTFILES: " (path :home))]
          ["template list output" @[hey-bin "template" "list"] "editorconfig" "go" "java" "practice" "rust"]
          ["template init rust output" @[hey-bin "template" "init" "rust" template-target] "template rust initialized"]
          ["template init dry-run output" @[hey-bin "-!" "template" "init" "rust" "/tmp/hey-rust-template"] "DRYRUN: mkdir -p /tmp/hey-rust-template" "DRYRUN: rsync -a"]
          ["doctor daily dry-run delegates quietly" @[hey-bin "-!" "doctor"] "hey doctor env --quiet" "hey ssh doctor --quiet"]
          ["doctor agents uses capability manifest" @[hey-bin "-!" "doctor" "agents"] "DRYRUN: check generated capability manifest"]
          ["doctor fix stale paths output" @[hey-bin "-!" "doctor" "fix" "stale-store-paths"] "DRYRUN: hey sync" "stale generated store path fix complete"]
          ["doctor fix tmux env output" @[hey-bin "-!" "doctor" "fix" "tmux-env"] "DRYRUN: tmux set-environment -g DOTFILES_HOME" "DRYRUN: hey reload tmux"]
          ["doctor fix zsh cache output" @[hey-bin "-!" "doctor" "fix" "zsh-cache"] "DRYRUN: " "hey clean zsh"]
          ["host list external output" @[hey-bin "-!" "host" "list" "--flake" "/tmp/site"] "/tmp/site#darwinConfigurations" "/tmp/site#nixosConfigurations"]
          ["host explain declared metadata output" @[hey-bin "host" "explain" "laptop" "--flake" host-fixture] "profiles:" "role: workstation" "workstation: enabled" "enabled modules:" "shell.tmux" "shell.zsh"]
          ["host explain dry-run output" @[hey-bin "-!" "host" "explain" "laptop" "--flake" host-fixture] "DRYRUN: resolve host kind" "DRYRUN: evaluate host system"]
          ["check external flake output" @[hey-bin "-!" "check" "--flake" "/tmp/site" "flake"] "DRYRUN: build all flake checks for the current system from /tmp/site"]
          ["check external eval host output" @[hey-bin "-!" "check" "--flake" "/tmp/site" "eval" "vm-a"] "/tmp/site#darwinConfigurations.vm-a.system.drvPath" "/tmp/site#nixosConfigurations.vm-a.config.system.build.toplevel.drvPath"]
          ["check external build output" @[hey-bin "-!" "check" "--flake" "/tmp/site" "build" "vm-a"] "/tmp/site#darwinConfigurations.vm-a.system" "/tmp/site#nixosConfigurations.vm-a.config.system.build.toplevel"]
          ["image list external output" @[hey-bin "-!" "image" "list" "utm" "--flake" "/tmp/site"] "DRYRUN: nix eval --impure --json --no-write-lock-file /tmp/site#nixosConfigurations.utm.config.system.build.images"]
          ["image build external output" @[hey-bin "-!" "image" "build" "utm" "--flake" "/tmp/site"] "DRYRUN: nix build --impure /tmp/site#nixosConfigurations.utm.config.system.build.images.qemu-efi"]
          ["info commands output" @[hey-bin "info" "commands"] "\"dev\"" "\"ssh\"" "\"subcommands\""]
          ["watch flake observes checked package sources" @[hey-bin "-!" "watch" "flake"] "--exts nix,rs,toml,lock,py,janet,zsh,sh,json,md" "check flake"]
          ["watch external flake output" @[hey-bin "-!" "watch" "flake" "--flake" "/tmp/site"] "--exts nix,rs,toml,lock,py,janet,zsh,sh,json,md" "check --flake /tmp/site flake"]
          ["watch eval host output" @[hey-bin "-!" "watch" "eval" "vm-a"] "--exts nix,janet" "hey check eval vm-a"]
          ["watch external eval host output" @[hey-bin "-!" "watch" "eval" "vm-a" "--flake" "/tmp/site"] "--exts nix,janet" "hey check --flake /tmp/site eval vm-a"]
          ["ssh doctor detects background sessions" @["env"
                                                       "HEY_SSH_DOCTOR_PS=101 2 S 00:10 ssh -N bastion"
                                                       "HEY_SSH_DOCTOR_LSOF="
                                                       hey-bin "ssh" "doctor"]
           "1 ssh tunnel-like process(es) found" "review: ps -fp 101" "terminate selected: kill 101"]
          ["ssh doctor suggests listening socket cleanup" @["env"
                                                            "HEY_SSH_DOCTOR_PS=201 2 S 00:10 ssh bastion"
                                                            "HEY_SSH_DOCTOR_LSOF=ssh 201 alice 3u IPv4 0x0 0t0 TCP 127.0.0.1:8080 (LISTEN)"
                                                            hey-bin "ssh" "doctor"]
           "1 listening ssh socket(s) found" "review: ps -fp 201" "terminate selected: kill 201"]
          ["tmux status fallback escapes fields" @["env"
                                                   "HEY_TMUX_STATUS_INPUT=direnv=1\tnix=impure#sdk\tbranch=feature#1\tfiles=2\tadded=3\tdeleted=4"
                                                   "zsh" (path :config "tmux/bin/status-right.zsh")]
           "impure##sdk" "feature##1" "~2" "+3" "-4"]
          ["vars get alias output" @["env" (string "XDG_RUNTIME_DIR=" runtime-home) (string "XDG_DATA_HOME=" data-home) hey-bin "get" "hey-check-key"] "hey-check-value"]
          ["eks env output" @["env" (string "XDG_CONFIG_HOME=" test-root "/hey-eks-check") hey-bin "eks" "env" "local-dev"] "export AWS_PROFILE='localprofile'" (string "export KUBECONFIG='" test-root "/hey-eks-check/hey/eks/kubeconfigs/local-dev.yaml'") "export KUBE_CONTEXT='localprofile/local-dev'" "export AWS_REGION='eu-west-1'" "export KUBE_NAMESPACE='app-ns'"]
          ["eks open default namespace output" @["env" (string "XDG_CONFIG_HOME=" test-root "/hey-eks-check") hey-bin "-!" "eks" "open" "local-dev"] "k9s --context localprofile/local-dev --namespace app-ns"]
          ["eks open explicit default namespace output" @["env" (string "XDG_CONFIG_HOME=" test-root "/hey-eks-check") hey-bin "-!" "eks" "open" "local-dev" "default"] "k9s --context localprofile/local-dev --namespace app-ns"]
          ["eks open all namespaces output" @["env" (string "XDG_CONFIG_HOME=" test-root "/hey-eks-check") hey-bin "-!" "eks" "open" "local-dev" "all"] "k9s --context localprofile/local-dev --all-namespaces"]
          ["eks open custom namespace output" @["env" (string "XDG_CONFIG_HOME=" test-root "/hey-eks-check") hey-bin "-!" "eks" "open" "local-dev" "custom-ns"] "k9s --context localprofile/local-dev --namespace custom-ns"]
          ["eks logs output" @["env" (string "XDG_CONFIG_HOME=" test-root "/hey-eks-check") hey-bin "-!" "eks" "logs" "local-dev" "api"] "stern api --context localprofile/local-dev --namespace app-ns"]
          ["eks port-forward output" @["env" (string "XDG_CONFIG_HOME=" test-root "/hey-eks-check") hey-bin "-!" "eks" "port-forward" "local-dev" "svc/api" "8080:80"] "kubectl --context localprofile/local-dev port-forward svc/api 8080:80 --namespace app-ns"]
          ["eks bastion port-forward output" @["env" (string "XDG_CONFIG_HOME=" test-root "/hey-eks-check") hey-bin "-!" "eks" "--bastion" "eks-bastion" "port-forward" "remote-dev" "svc/api" "8080:80" "default"] "ssh -t -L 127.0.0.1:8080:127.0.0.1:8080" "'hey' 'eks' 'port-forward' 'remote-dev' 'svc/api' '8080:80' 'default'"]]
        redaction-commands @[
          ["ssh doctor ignores disabled control master" @["env"
                                                          "HEY_SSH_DOCTOR_PS=102 2 S 00:10 ssh -o ControlMaster=no -o ControlPath=none bastion"
                                                          "HEY_SSH_DOCTOR_LSOF="
                                                          hey-bin "ssh" "doctor"]
           @["no ssh tunnel-like processes found"] @["1 ssh tunnel-like process(es) found"]]
          ["ssh doctor reports managed host ca trust" @["env"
                                                        (string "HOME=" ssh-fixture-home)
                                                        "HEY_SSH_DOCTOR_PS="
                                                        "HEY_SSH_DOCTOR_LSOF="
                                                        hey-bin "ssh" "doctor"]
           @["managed SSH host CA keys and unconditional user-config reference verified"
             "SSH user certificate is not installed"
             "SSH host certificate is not installed"]
           @["password=" "PRIVATE KEY"]]
          ["doctor env quiet suppresses successful details" @[;doctor-env-prefix hey-bin "doctor" "--quiet" "env"]
           @["environment doctor passed"] @["dotfiles path:" "host:" "theme:"]]
          ["ssh doctor quiet suppresses successful checks" @[hey-bin "-!" "ssh" "doctor" "--quiet"]
           @["DRYRUN: ps -ax -o pid=,ppid=,stat=,etime=,command="] @["no ssh processes found" "no zombie ssh processes found"]]
          ["zsh editor terminals keep full prompt" @["sed" "-n" "1,12p" (path :config "zsh/.zshrc")]
           @["TERM == dumb"] @["INSIDE_EMACS"]]
          ["zsh stale tmux env keeps right prompt"
           @["env" (string "TMUX=" test-root "/tmux-501/default,999,1") "TMUX_PANE=%999" "TERM=xterm-256color" "zsh" "-fc" (string "source " (path :themes "alucard/config/zsh/prompt.zsh") "; print -r -- right_count=${#POWERLEVEL9K_RIGHT_PROMPT_ELEMENTS}")]
           @["right_count=35"] @["right_count=0"]]
          ["doctor secrets clean" @["env" (string "HEY_DOCTOR_SECRET_PATHS=" host-fixture) hey-bin "doctor" "secrets"] @["no inline secret markers found"] @["tskey-auth" "::server:"]]
          ["doctor secrets clean age env" @["env" (string "HEY_DOCTOR_SECRET_PATHS=" host-fixture) hey-bin "doctor" "secrets"] @["no inline secret markers found"] @["SOPS_AGE_KEY="]]
          ["project status output" @[hey-bin "project" "status"] @["root:" "language:"] @["password="]]
          ["doctor secrets redacts kubernetes password" @["env" (string "HEY_DOCTOR_SECRET_PATHS=" secret-fixture) hey-bin "doctor" "secrets"]
           @["secret.yaml\":4: inline secret marker"]
           @["VEVTVA=="]]]
        failure-commands @[
          ["top-level unknown command" @[hey-bin "definitely-nope"] "Unknown command: \"definitely-nope\""]
          ["doctor agents rejects unsupported capability schema"
           @["env" (string "XDG_DATA_HOME=" capability-fixture-home) hey-bin "doctor" "agents"]
           "capability manifest schema version 1 is supported"]
          ["eks unavailable without aws host config" @["env" (string "XDG_CONFIG_HOME=" test-root "/hey-eks-missing") hey-bin "-!" "eks" "list"] "hey eks is not available on this host"]
          ["eks unknown cluster" @["env" (string "XDG_CONFIG_HOME=" test-root "/hey-eks-check") hey-bin "-!" "eks" "kubeconfig" "nope"] "Unknown EKS cluster: nope"]
          ["eks vpn rejects missing cluster" @["env" (string "XDG_CONFIG_HOME=" test-root "/hey-eks-check") hey-bin "-!" "eks" "vpn" "status"] "Usage: hey eks vpn status|start|restart|logs CLUSTER"]
          ["eks vpn rejects unknown action" @["env" (string "XDG_CONFIG_HOME=" test-root "/hey-eks-check") hey-bin "-!" "eks" "vpn" "nope" "remote-dev"] "Usage: hey eks vpn status|start|restart|logs CLUSTER"]
          ["eks use rejects extra args" @["env" (string "XDG_CONFIG_HOME=" test-root "/hey-eks-check") hey-bin "-!" "eks" "use" "remote-dev" "extra"] "Usage: hey eks use CLUSTER"]
          ["eks open rejects extra args" @["env" (string "XDG_CONFIG_HOME=" test-root "/hey-eks-check") hey-bin "-!" "eks" "open" "remote-dev" "one" "two"] "Usage: hey eks open CLUSTER [default|all|NAMESPACE]"]
          ["eks logs rejects extra args" @["env" (string "XDG_CONFIG_HOME=" test-root "/hey-eks-check") hey-bin "-!" "eks" "logs" "remote-dev" "one" "two" "three"] "Usage: hey eks logs CLUSTER [QUERY] [default|all|NAMESPACE]"]
          ["eks port-forward requires mapping" @["env" (string "XDG_CONFIG_HOME=" test-root "/hey-eks-check") hey-bin "-!" "eks" "port-forward" "remote-dev" "svc/api"] "Usage: hey eks port-forward CLUSTER RESOURCE LOCAL:REMOTE [default|NAMESPACE]"]
          ["eks port-forward rejects all namespaces" @["env" (string "XDG_CONFIG_HOME=" test-root "/hey-eks-check") hey-bin "-!" "eks" "port-forward" "local-dev" "svc/api" "8080:80" "all"] "Port-forward requires a single namespace"]
          ["eks port-forward rejects malformed mapping" @["env" (string "XDG_CONFIG_HOME=" test-root "/hey-eks-check") hey-bin "-!" "eks" "port-forward" "local-dev" "svc/api" "8080"] "Port mapping must be LOCAL:REMOTE"]
          ["eks env rejects extra args" @["env" (string "XDG_CONFIG_HOME=" test-root "/hey-eks-check") hey-bin "-!" "eks" "env" "remote-dev" "extra"] "Usage: hey eks env CLUSTER"]
          ["dot dispatch unknown without desktop" @["env" "-u" "XDG_CURRENT_DESKTOP" hey-bin ".definitely-nope"] ".definitely-nope: command not found"]
          ["build rejects unknown option" @[hey-bin "-!" "build" "--bad"] "Usage: hey build [-a]"]
          ["build all rejects extra args" @[hey-bin "-!" "build" "-a" "extra"] "Usage: hey build [-a]"]
          ["build iso rejects extra args" @[hey-bin "-!" "build" "iso" "extra"] "Usage: hey build iso"]
          ["build unknown subcommand" @[hey-bin "build" "nope"] "Unknown build command: nope"]
          ["check fixed subcommand rejects extra args" @[hey-bin "check" "cli" "extra"] usage]
          ["check all rejects extra args" @[hey-bin "check" "all" "one" "two"] usage]
          ["check unit rejects extra args" @[hey-bin "check" "unit" "extra"] usage]
          ["check flake rejects extra args" @[hey-bin "check" "flake" "extra"] usage]
          ["check build rejects extra args" @[hey-bin "check" "build" "utm" "extra"] "Usage: hey check build HOST"]
          ["clean unknown target" @[hey-bin "-!" "clean" "nope"] "Usage: hey clean [all|zsh|nix|k9s|cache]"]
          ["context rejects extra args" @[hey-bin "context" "extra"] "Usage: hey context"]
          ["dev unknown subcommand" @[hey-bin "dev" "nope"] "Usage: hey dev doctor|status|tools|shell|check|test|ci|up|down|logs|services|watch|profile|disk|git|clean [ARGS...] [--yes]"]
          ["dev rejects extra args" @[hey-bin "-!" "dev" "check" "extra"] "Usage: hey dev doctor|status|tools|shell|check|test|ci|up|down|logs|services|watch|profile|disk|git|clean [ARGS...] [--yes]"]
          ["doctor unknown subcommand" @[hey-bin "doctor" "nope"] "Usage: hey doctor [--quiet|--verbose]"]
          ["doctor rejects extra args" @[hey-bin "-!" "doctor" "nix" "extra"] "Usage: hey doctor [--quiet|--verbose]"]
          ["doctor fix rejects unknown target" @[hey-bin "-!" "doctor" "fix" "nope"] "Usage: hey doctor [--quiet|--verbose]"]
          ["gc rejects extra args" @[hey-bin "-!" "gc" "extra"] "Usage: hey gc [-a|--all] [-s|--system] [-d]"]
          ["host list rejects extra args" @[hey-bin "-!" "host" "list" "extra"] "Usage: hey host doctor HOST [--flake FLAKE] [--storage] | hey host explain HOST [--flake FLAKE] | hey host list [--flake FLAKE] | hey host COMMAND [ARGS...]"]
          ["hook requires name" @[hey-bin "hook"] "Usage: hey hook HOOK [ARGS...]"]
          ["template init rejects nonempty target" @[hey-bin "template" "init" "rust" template-nonempty] "Target directory is not empty"]
          ["template rejects unknown template" @[hey-bin "-!" "template" "init" "nope"] "Unknown template: nope"]
          ["image unknown subcommand" @[hey-bin "image" "nope" "utm"] "Usage: hey image list HOST [--flake FLAKE] | hey image build HOST [VARIANT] [--flake FLAKE]"]
          ["image list rejects extra args" @[hey-bin "-!" "image" "list" "utm" "extra"] "Usage: hey image list HOST [--flake FLAKE] | hey image build HOST [VARIANT] [--flake FLAKE]"]
          ["image build rejects extra args" @[hey-bin "-!" "image" "build" "utm" "qemu-efi" "extra"] "Usage: hey image list HOST [--flake FLAKE] | hey image build HOST [VARIANT] [--flake FLAKE]"]
          ["project unknown subcommand" @[hey-bin "project" "nope"] "Usage: hey project doctor|status|shell|check|test|ci|up|down|logs|services|watch|profile|disk|git|clean [ARGS...] [--yes]"]
          ["project rejects extra args" @[hey-bin "-!" "project" "check" "extra"] "Usage: hey project doctor|status|shell|check|test|ci|up|down|logs|services|watch|profile|disk|git|clean [ARGS...] [--yes]"]
          ["ssh unknown subcommand" @[hey-bin "ssh" "nope"] "Usage: hey ssh doctor | hey ssh ps"]
          ["automatic ssh termination removed" @[hey-bin "-!" "ssh" "kill-stale"] "Automatic SSH termination was removed"]
          ["ssh doctor rejects extra args" @[hey-bin "-!" "ssh" "doctor" "extra"] "Usage: hey ssh doctor"]
          ["tmux unknown subcommand" @[hey-bin "tmux" "nope"] "Usage: hey tmux clean | hey tmux doctor | hey tmux project [NAME] [PATH] | hey tmux sessions | hey tmux swap-pane left|right|up|down|master"]
          ["tmux reload removed" @[hey-bin "-!" "tmux" "reload"] "Usage: hey tmux clean | hey tmux doctor | hey tmux project [NAME] [PATH] | hey tmux sessions | hey tmux swap-pane left|right|up|down|master"]
          ["tmux swap-pane rejects extra args" @[hey-bin "-!" "tmux" "swap-pane" "left" "extra"] "Usage: hey tmux swap-pane left|right|up|down|master"]
          ["path xdg requires directory" @[hey-bin "path" "xdg"] "Usage: hey path xdg DIR [SEGMENTS...]"]
          ["swap mutations removed" @[hey-bin "swap" "--reset"] "Swap mutations were removed"]
          ["vars get requires key" @[hey-bin "vars" "get"] "Usage: hey vars get KEY"]
          ["vars get rejects extra args" @[hey-bin "vars" "get" "key" "extra"] "Usage: hey vars get KEY"]
          ["vars set requires value" @[hey-bin "vars" "set" "onlykey"] "Usage: hey vars set KEY VALUE"]
          ["vars set rejects extra args" @[hey-bin "vars" "set" "key" "value" "extra"] "Usage: hey vars set KEY VALUE"]
          ["vars ls rejects extra args" @[hey-bin "vars" "ls" "extra"] "Usage: hey vars [ls|get|set]"]
          ["vars unknown subcommand" @[hey-bin "vars" "nope"] "Usage: hey vars [ls|get|set]"]
          ["repl rejects conflicting modes" @[hey-bin "repl" "-j" "-d"] "Usage: hey repl [-j|-d] [ARGS...]"]
          ["search requires query" @[hey-bin "search"] "Usage: hey search [--json] [--from INSTALLABLE] QUERY..."]
          ["reload unknown target" @[hey-bin "-!" "reload" "nope"] "Usage: hey reload [all|tmux|zsh|direnv|k9s|cache]"]
          ["reload rejects extra args" @[hey-bin "-!" "reload" "tmux" "extra"] "Usage: hey reload [all|tmux|zsh|direnv|k9s|cache]"]
          ["sync rollback requires generation" @["env" (string "XDG_DATA_HOME=" data-home) hey-bin "sync" "rollback"] "Usage: hey sync rollback GENERATION"]
          ["watch unknown subcommand" @[hey-bin "watch" "nope"] "Usage: hey watch eval [HOST] [--flake FLAKE] | hey watch cli | hey watch flake [--flake FLAKE] | hey watch tmux | hey watch utm-cli | hey watch run COMMAND [ARGS...]"]
          ["watch fixed subcommand rejects extra args" @[hey-bin "-!" "watch" "cli" "extra"] "Usage: hey watch eval [HOST] [--flake FLAKE] | hey watch cli | hey watch flake [--flake FLAKE] | hey watch tmux | hey watch utm-cli | hey watch run COMMAND [ARGS...]"]
          ["watch eval rejects extra args" @[hey-bin "-!" "watch" "eval" "one" "two"] "Usage: hey watch eval [HOST] [--flake FLAKE] | hey watch cli | hey watch flake [--flake FLAKE] | hey watch tmux | hey watch utm-cli | hey watch run COMMAND [ARGS...]"]
          ["profile rm requires generation" @[hey-bin "profile" "rm"] "Usage: hey profile rm GEN"]
          ["profile ls rejects extra args" @[hey-bin "profile" "ls" "extra"] "Usage: hey profile ls|rm|diff"]
          ["profile diff rejects extra args" @[hey-bin "profile" "diff" "1" "2" "3"] "Usage: hey profile diff [FROM] [TO]"]
          ["profile unknown subcommand" @[hey-bin "profile" "nope"] "Usage: hey profile ls|current|previous|rollback|rm|prune|diff"]
          ["ops removed" @[hey-bin "ops"] "Unknown command: \"ops\""]
          ["pull override rejects malformed input" @[hey-bin "-!" "pull" "-o" "bad"] "Malformed input spec: bad"]]]
    (var ok true)
    # Never depend on or inspect a developer/CI host's real system generations.
    # Both profile selection and previous-generation coverage use scratch data.
    (each generation ["1" "2"]
      (path/mkdirp (string profile-state-home "/nix/profiles/profile-" generation "-link")))
    (os/link "profile-2-link" (string profile-state-home "/nix/profiles/profile") true)
    (path/mkdirp (string "" test-root "/hey-eks-check/hey"))
    (spit (string "" test-root "/hey-eks-check/hey/aws.json")
          "{\"awscli2\":{\"samlAccounts\":[\"remoteprofile\"],\"eksClusters\":{\"remote-dev\":{\"name\":\"remote-dev\",\"profile\":\"remoteprofile\",\"region\":\"eu-central-1\",\"kubeContext\":\"remoteprofile/remote-dev\",\"bastion\":\"eks-bastion\",\"vpnService\":\"openvpn-eks.service\"},\"local-dev\":{\"name\":\"local-dev\",\"profile\":\"localprofile\",\"region\":\"eu-west-1\",\"kubeContext\":\"localprofile/local-dev\",\"namespace\":\"app-ns\"}}}}")
    (path/rmtree secret-fixture)
    (path/mkdirp secret-fixture)
    # Base64 for the literal TEST; deliberately not a realistic password.
    (spit (string secret-fixture "/secret.yaml")
          "apiVersion: v1\nkind: Secret\ndata:\n  password: VEVTVA==\n")
    (path/rmtree ssh-fixture-home)
    (path/mkdirp (string ssh-fixture-home "/.ssh/config.d"))
    # Synthetic all-zero public key; never copy a consumer's host CA into fixtures.
    (spit (string ssh-fixture-home "/.ssh/nixi_known_hosts")
          "@cert-authority laptop,server ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA synthetic test host ssh ca\n")
    (spit (string ssh-fixture-home "/.ssh/config")
          "Include ~/.ssh/config.d/*.conf\n")
    (spit (string ssh-fixture-home "/.ssh/config.d/nixi-host-ca.conf")
          "Host *\n  UserKnownHostsFile ~/.ssh/nixi_known_hosts ~/.ssh/known_hosts\n")
    (path/rmtree capability-fixture-home)
    (path/mkdirp (string capability-fixture-home "/hey"))
    (spit (string capability-fixture-home "/hey/capabilities.json")
          "{\"version\":999,\"groups\":{}}\n")
    (path/rmtree project-fixture)
    (path/mkdirp project-fixture)
    (spit (string project-fixture "/Cargo.toml") "[package]\nname = 'fixture'\nversion = '0.1.0'\n")
    (spit (string project-fixture "/process-compose.yaml")
          "version: \"0.5\"\nprocesses:\n  db:\n    command: \"sleep 60\"\n")
    (spit (string project-fixture "/flake.nix")
          "{ outputs = _: {}; }\n")
    (path/rmtree template-target)
    (path/rmtree template-nonempty)
    (path/mkdirp template-nonempty)
    (spit (string template-nonempty "/existing") "existing\n")
    (each [label args] commands
      (unless (check-command label args)
        (set ok false)))
    (each [label args & needles] help-commands
      (unless (check-command-output-contains label args ;needles)
        (set ok false)))
    (each [label args needles forbidden] redaction-commands
      (unless (check-command-output-contains-not label args needles forbidden)
        (set ok false)))
    (each [label args & needles] failure-commands
      (unless (check-command-fails-output-contains label args ;needles)
        (set ok false)))
    (unless (check-command-manifest)
      (set ok false))
    (unless (check-help-pages hey-bin)
      (set ok false))
    (unless ok
      (exit 1))))
