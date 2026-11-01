#!/usr/bin/env janet
# Manage UTM-backed NixOS VMs.
#
# SYNOPSIS:
#   utm ls
#   utm status VM
#   utm start VM
#   utm stop VM
#   utm create-image --vm VM --flake FLAKE#HOST [--cpu N] [--ram MiB] [--phases PHASES] [--force] [--yes]
#   utm doctor VM [--user USER] [--wait SECONDS]
#   utm update VM [--flake FLAKE#HOST] [--user USER] [--mode switch] [--wait SECONDS]
#   utm rollback VM [--user USER] [--wait SECONDS]
#   utm generations VM [--user USER] [--wait SECONDS]
#   utm cleanup-generations VM [--user USER] [--wait SECONDS] [--keep-generations N]
#   utm diff VM [--flake FLAKE#HOST] [--user USER] [--wait SECONDS]
#   utm ssh VM [--user USER] [COMMAND...]
#   utm current VM [--user USER]
#   utm check VM [--user USER] [--wait SECONDS]
#   utm ip VM [--scan] [--wait SECONDS]
#     IP discovery is passive by default. --scan permits a local /24 ping
#     sweep with at most eight concurrent probes. --wait can shorten the
#     shared 30-second deadline; dry runs never probe or scan.
#   utm token VM

(use hey)
(use hey/vm)
(use hey/ssh)
(use hey/nix)
(use hey/image)
(use hey/cmd)
(use spork/sh)

(import ./path)
(import hey/process)
(import hey/vm-policy)

(def- setup-vm-image-tpl ``
      on run argv
        set vm_name to item 1 of argv
        set vm_mac to item 2 of argv
        set disk_path to item 3 of argv
        set disk_file to "file://" & disk_path as POSIX file
        tell application "UTM"
            set theDrive to {{source:disk_file}}
            set theNetwork to {{address:vm_mac, mode:bridged, host interface:"en0"}}
            set theConfiguration to {name:vm_name, architecture:"aarch64", drives:theDrive, network interfaces:theNetwork}
            set vm to make new virtual machine with properties {backend:apple, configuration:theConfiguration}
        end tell
      end run``)

# Display = [
      # {
      #   HeightPixels = 1200;
      #   WidthPixels = 1920;
      #   PixelsPerInch = 226;
      #   DynamicResolution = true;
      # }
#     ];
(def- utm-config-tpl ``
  {
    System = {
      CPUCount = %d;
      MemorySize = %d;
    };
    Virtualization = {
      Audio = true;
      Balloon = true;
      ClipboardSharing = true;
      Keyboard = true;
      Pointer = true;
      Rosetta = false;
      Trackpad = true;
      Entropy = true;
    };
  }``)

(defn- command-output [args]
  (ignore-errors (process/output args 30)))

(defn- ptty-from-attach-output [out]
  (first
    (keep
      (fn [line]
        (let [line (string/trim line)
              prefix "PTTY: "]
          (when (string/has-prefix? prefix line)
            (string/slice line (length prefix)))))
      (string/split "\n" (or out "")))))

(defn- utm/attach [vm-name]
"Attach to the VM and extract the pseudo-TTY path."
  (var tt nil)
  (while (nil? tt)
    (set tt (ptty-from-attach-output
              (command-output @["utmctl" "attach" (string vm-name)])))
    (os/sleep 1))
  tt)

  (defn read-from-file [file-path]
    (let [f (file/open file-path :r)
          content  (file/read f :all)]
      (file/close f)
      content))

(defn- utm/tty [& args]
  (let [tty (utm/attach (get args 0))
        cmd (get args 1)
        dat (file/temp)]
    (defer (cleanup-temp-files [(string dat)]) [(with [proc (os/spawn ["cat" (string/trim tty)] :p {:out dat})]
                                                      (with [fd-tty (file/open (string/trim tty) :w)]
                                                            ($ echo -e ,cmd >,fd-tty)
                                                            (os/sleep 0.3)
                                                            (os/proc-kill proc)
                                                            (os/proc-wait proc) # => 0
                                                            (file/seek dat :set 0)
                                                            (let [content (file/read dat :all)]
                                                              content)))])))
  



(defn- assert [fnAssert msg]
  (if (not (fnAssert))
    ((echo :error msg)
     (exit 1))))

(def- *ctx* @{})

(def- allowed-phases ["start" "doctor"])

(defn- parse-phases [phases]
  (let [parsed @{}]
    (each phase (filter |(not (empty? $)) (string/split "," phases))
      (unless (index-of phase allowed-phases)
        (abort "Unknown UTM create-image phase: %s" phase))
      (put parsed phase true))
    parsed))

(def simplified-combined-grammar
  (peg/compile
   ~{:main (% (any :segment)) # Collect all processed segments into a string 

     # A segment can be a specific pattern to remove/extract, or a single character
     # Order matters: try most specific/complex transformations first 
     :segment (+ :extract-colored-text
                 :remove-window-title
                 :remove-generic-ansi-code
                 (<- 1)) # Fallback: match any single character

     :esc "\u001B"
     :bel "\a"

     # General ANSI CSI code to be removed (e.g., \e[?2004l, \e[?2004h, \e[1;32m, \e[0m)
     # This rule matches ESC [, then any characters that are not 'm' or BEL,
     # followed by 'm' or BEL. This covers most common CSI sequences.
     :generic-ansi-code (* :esc "[" (any (if-not (+ "m" :bel) 1)) (+ "m" :bel))
     :remove-generic-ansi-code (/ (<- :generic-ansi-code) "")

     # Rules to remove window titles
     :window-title-start (* :esc "]0;")
     :window-title-end (* (some (if-not :bel 1)) (+ :bel))
     :window-title-pattern (* :window-title-start :window-title-end)
     :remove-window-title (/ (<- :window-title-pattern) "")

     # Rules for colored text extraction (more general)
     # Matches \e[ then one or more digits, optionally followed by ; and more digits, ending with m 
     :ansi-color-start (* :esc "[" (some :d) (any (* ";" (some :d))) "m")
     :ansi-color-end (* :esc "[0m")

     # This rule matches the content inside the color codes.
     # It recursively applies the :segment rules to process its own content,
     # ensuring nested patterns (like window titles) are handled.
     # The (%) ensures this rule itself produces a string.
     :colored-text-inner-content (% (any (if-not :ansi-color-end :segment)))

     # This rule matches the full colored text sequence, but only the
     #  :colored-text-inner-content contributes to the final output.
     # (unref ...) discards the matched parts, allowing only the result
     # :colored-text-inner-content to pass through.
     :extract-colored-text (* (unref :ansi-color-start)
                              :colored-text-inner-content
                              (unref :ansi-color-end))}))

(defn- utm/run [vm cmd]
  (if-let [out (utm/tty vm cmd)]
    (->> (mapcat |(peg/match simplified-combined-grammar $) out)
         (mapcat |(string/split "\r\n" $))
         (filter |(not= $ "\r"))
         (filter |(not (empty? $)))
         (filter |(not= $ cmd)))
    []))

(defn- image-target [flake-ref host]
  (nix/nixos-image-target flake-ref host))

(defn- toplevel-target [flake-ref host]
  (nix/nixos-toplevel-target flake-ref host))

(defn- build-toplevel [flake-ref host]
  (image/build-toplevel flake-ref host))

(defn- utm/ip [vm]
  (string/trim ($< hey utm ip ,vm)))

(defn- remote-trim [ssh-opts conn cmd]
  (string/trim (ssh/slurp ssh-opts conn cmd)))

(defn- remote-chomp [ssh-opts conn cmd]
  (string/chomp (ssh/slurp ssh-opts conn cmd)))

(defn- format-generations [generations]
  (string/join (map string/trim (string/split "\n" generations)) "\n"))

(defn- remote-system-profile []
  "readlink -f /nix/var/nix/profiles/system")

(defn- remote-current-system []
  "readlink -f /run/current-system")

(defn- remote-password-auth []
  (string (slurp (path :framework "runtime/hey/ssh-policy.sh"))))

(defn- remote-activation-sudo []
  "cmd=$(readlink -f /run/current-system/bin/switch-to-configuration); sudo -n -l \"$cmd\" switch >/dev/null && printf yes || printf no")

(defn- remote-set-system-profile-cmd [out]
  (string "nix_env=$(readlink /run/current-system/sw/bin/nix-env); sudo -n \"$nix_env\" --profile /nix/var/nix/profiles/system --set " out))

(defn- remote-rollback-system-profile-cmd []
  "nix_env=$(readlink /run/current-system/sw/bin/nix-env); sudo -n \"$nix_env\" --profile /nix/var/nix/profiles/system --rollback")

(defn- remote-list-system-generations-cmd []
  "nix_env=$(readlink /run/current-system/sw/bin/nix-env); sudo -n \"$nix_env\" --profile /nix/var/nix/profiles/system --list-generations")

(defn- remote-delete-system-generations-cmd [keep]
  (string "nix_env=$(readlink /run/current-system/sw/bin/nix-env); sudo -n \"$nix_env\" --profile /nix/var/nix/profiles/system --delete-generations +" keep))

(defn- remote-hey-info []
  "cat \"${XDG_DATA_HOME:-$HOME/.local/share}/hey/info.json\"")

(defn- assert-remote-eq [label actual expected]
  (if (= actual expected)
    (echof :check "%s" label)
    (abort "%s: expected %s, got %s" label expected actual)))

(defn- assert-remote-ok [label ok?]
  (if ok?
    (echof :check "%s" label)
    (abort "%s" label)))

(defn- verify-activation [ssh-opts conn &opt expected-system]
  (echof :g "> Verifying activation on %s" conn)
  (assert-remote-ok "SSH batch login works"
                    (= 0 (ssh/run-quiet ssh-opts conn "true")))
  (let [current (remote-trim ssh-opts conn (remote-current-system))
        profile (remote-trim ssh-opts conn (remote-system-profile))
        password-auth (remote-trim ssh-opts conn (remote-password-auth))
        activation-sudo (remote-trim ssh-opts conn (remote-activation-sudo))]
    (when expected-system
      (assert-remote-eq "Current system matches built toplevel" current expected-system))
    (assert-remote-eq "Current system matches system profile" current profile)
    (assert-remote-eq "Effective SSH password authentication is disabled for this connection" password-auth "no")
    (assert-remote-eq "Passwordless activation sudo rule matches" activation-sudo "yes")))

(defn- remote-vm-state [ssh-opts conn]
  @{:current (remote-trim ssh-opts conn (remote-current-system))
    :profile (remote-trim ssh-opts conn (remote-system-profile))
    :password-auth (remote-trim ssh-opts conn (remote-password-auth))
    :activation-sudo (remote-trim ssh-opts conn (remote-activation-sudo))})

(defn- ssh-run-check [ssh-opts conn remote-cmd]
  (let [status (execute-clean (ssh/args ssh-opts conn remote-cmd))]
    (unless (= 0 status)
      (error (string/format "ssh command failed with exit code %d" status)))
    true))

(defn- utm-ssh-context [vm user wait-seconds]
  (let [ip (utm/ip vm)
        conn (ssh/connection user ip)
        ssh-opts (ssh/trusted-options)]
    (when (empty? ip)
      (abort "Could not resolve IP for UTM VM %s" vm))
    (echof :g "> Waiting for SSH on %s" conn)
    (ssh/wait ssh-opts conn wait-seconds)
    @{:ip ip :conn conn :ssh-opts ssh-opts}))

(defn- remote-vm-image-profile [ssh-opts conn]
  (vm-policy/decode (remote-trim ssh-opts conn (remote-hey-info))))

(defn- cleanup-system-generations [ssh-opts conn keep]
  (vm-policy/validate-keep keep)
  (echof :g "> Keeping last %d system generations on %s" keep conn)
  (do? $ ssh ,;ssh-opts ,conn ,(remote-delete-system-generations-cmd keep))
  (let [current (remote-trim ssh-opts conn (remote-current-system))]
    (echof :g "> Updating boot entries after generation cleanup on %s" conn)
    (do? $ ssh ,;ssh-opts ,conn sudo -n ,(string current "/bin/switch-to-configuration") boot)
    (verify-activation ssh-opts conn current)))

(defn- maybe-cleanup-system-generations [ssh-opts conn keep]
  (when keep
    (cleanup-system-generations ssh-opts conn keep)))

(defn- prepare-image-copy [ctx]
  (image/prepare-utm-copy (ctx :flake-ref) (ctx :flake)))

(defn- confirm-force [vm yes?]
  (unless yes?
    (printf "Delete and recreate VM %s? Type %s to continue: " vm vm)
    (flush)
    (let [answer (string/trim (file/read stdin :line))]
      (unless (= answer vm)
        (abort "Abort.")))))

(defn- replace-existing-vm [ctx]
  (let [vm (ctx :vm)
        yes? (ctx :yes)]
    (when (vm/exists? vm)
      (confirm-force vm yes?)
      (when (utm/started? vm)
        (echo :g "> Stop a virtual machine.")
        (utm/stop vm)
        (os/sleep 2))
      (echo :g "> Delete virtual machine.")
      (utm/delete vm)
      (vm/wait-for vm false))))

(defn- utm/create-image [ctx]
  (let [{:vm vm :flake flake} ctx]
    (vm/validate-name vm)
    (assert |(|(and (not (nil? $)) (> (length $) 0)) flake) "param flake is not set"))

  (if (dryrun?)
    (do
      (echof "DRYRUN: $ nix build --impure --print-out-paths %s" (image-target (ctx :flake-ref) (ctx :host)))
      (echof "DRYRUN: convert and validate qcow2 in a private staging directory under %s" (image/utm-workdir))
      (when (ctx :force)
        (echof "DRYRUN: after the replacement image is ready, confirm, stop and delete existing VM %s" (ctx :vm)))
      (echof "DRYRUN: create UTM VM %s from converted raw image" (ctx :vm))
      (when (get (ctx :phases) "doctor" false)
        (echof "DRYRUN: run hey utm doctor %s" (ctx :vm))))
    (do
      (when (and (vm/exists? (ctx :vm)) (not (ctx :force)))
        (abort "The VM [%s] exists. Use --force to replace it." (ctx :vm)))

      (let [image-copy (prepare-image-copy ctx)]
        (var complete? false)
        (defer (unless complete?
                 (echof :warn "Replacement image retained at %s; inspect UTM before retrying." image-copy))
          (if (ctx :force)
            (replace-existing-vm ctx)
            (when (vm/exists? (ctx :vm))
              (abort "VM %s appeared while preparing the image; refusing to replace it." (ctx :vm))))
          (echof :g "## Creating image-backed VM [%s]." (ctx :vm))
          (put ctx :image image-copy)
          (put ctx :vm-config setup-vm-image-tpl)
          (vm/create ctx)
          (vm/wait-for (ctx :vm) true)
          (os/rm image-copy)
          (os/rmdir (path/dirname image-copy))
          (set complete? true))))))

(defn- utm/update [ctx]
  (unless (= (ctx :mode) "switch")
    (abort "hey utm update supports only --mode switch; test/boot/dry-activate are not deployment modes"))
  (let [vm (ctx :vm)
        flake-ref (ctx :flake-ref)
        host (ctx :host)
        user (ctx :user)
        mode (ctx :mode)
        wait-seconds (ctx :wait)
        keep-generations (ctx :keep-generations)
        target (toplevel-target flake-ref host)]
    (assert |(|(and (not (nil? $)) (> (length $) 0)) vm) "param vm is not set")
    (assert |(|(and (not (nil? $)) (> (length $) 0)) host) "param host is not set")
    (if (dryrun?)
      (do
        (echof "DRYRUN: resolve VM IP with: hey utm ip %s" vm)
        (echof "DRYRUN: preserve known_hosts and verify the server host key")
        (echof "DRYRUN: wait up to %d seconds for SSH batch login" wait-seconds)
        (echof "DRYRUN: nix build --impure --print-out-paths %s" target)
        (echof "DRYRUN: compare <toplevel> with remote current/profile")
        (echof "DRYRUN: if already current, verify and skip activation")
        (echof "DRYRUN: nix copy --to ssh://%s@<ip> <toplevel>" user)
        (echof "DRYRUN: ssh -t %s@<ip> sudo -n <toplevel>/bin/switch-to-configuration %s" user mode)
        (echof "DRYRUN: ssh %s@<ip> sudo -n <nix-env> --profile /nix/var/nix/profiles/system --set <toplevel>" user)
        (echof "DRYRUN: ssh %s@<ip> sudo -n <toplevel>/bin/switch-to-configuration boot" user)
        (echof "DRYRUN: verify SSH, current/profile match, password auth, and activation sudo")
        (if keep-generations
          (echof "DRYRUN: if enabled by remote profile, keep last %d system generations" keep-generations)
          (echof "DRYRUN: if enabled by remote profile, keep its configured number of system generations")))
      (let [remote (utm-ssh-context vm user wait-seconds)
            conn (remote :conn)
            ssh-opts (remote :ssh-opts)
            # Validate a single policy snapshot before any deployment mutations.
            cleanup-keep (vm-policy/automatic-keep
                           (remote-vm-image-profile ssh-opts conn) keep-generations)]
        (echof :g "> Building %s" target)
        (let [out (build-toplevel flake-ref host)]
          (when (empty? out)
            (abort "nix build did not return a toplevel output for %s" host))
          (let [state (remote-vm-state ssh-opts conn)]
            (if (and (= out (state :current))
                     (= out (state :profile)))
              (do
                (echof :check "Already current: %s" out)
                (verify-activation ssh-opts conn out)
                (maybe-cleanup-system-generations ssh-opts conn cleanup-keep)
                (echo :check "Done!"))
              (do
                (echof :g "> Copying closure to %s" conn)
                (with-envvars ["NIX_SSHOPTS" (string/join ssh-opts " ")]
                  (do? $ nix copy --to ,(string "ssh://" conn) ,out))
                (echof :g "> Activating %s on %s" out conn)
                (do? $ ssh ,;ssh-opts -t ,conn sudo -n ,(string out "/bin/switch-to-configuration") ,mode)
                (echof :g "> Setting system profile to %s on %s" out conn)
                (do? $ ssh ,;ssh-opts ,conn ,(remote-set-system-profile-cmd out))
                (echof :g "> Updating boot entries for %s on %s" out conn)
                (do? $ ssh ,;ssh-opts ,conn sudo -n ,(string out "/bin/switch-to-configuration") boot)
                (verify-activation ssh-opts conn out)
                # Activation can change the installed policy, including opting
                # out. Revalidate it before deleting any generations.
                (maybe-cleanup-system-generations ssh-opts conn
                  (vm-policy/automatic-keep
                    (remote-vm-image-profile ssh-opts conn) keep-generations))
                (echo :check "Done!")))))))))

(defn- utm/rollback [ctx]
  (let [vm (ctx :vm)
        user (ctx :user)
        wait-seconds (ctx :wait)]
    (assert |(|(and (not (nil? $)) (> (length $) 0)) vm) "param vm is not set")
    (if (dryrun?)
      (do
        (echof "DRYRUN: resolve VM IP with: hey utm ip %s" vm)
        (echof "DRYRUN: preserve known_hosts and verify the server host key")
        (echof "DRYRUN: wait up to %d seconds for SSH batch login" wait-seconds)
        (echof "DRYRUN: ssh %s@<ip> sudo -n <nix-env> --profile /nix/var/nix/profiles/system --rollback" user)
        (echof "DRYRUN: ssh %s@<ip> sudo -n <rolled-back-system>/bin/switch-to-configuration switch" user)
        (echof "DRYRUN: ssh %s@<ip> sudo -n <rolled-back-system>/bin/switch-to-configuration boot" user)
        (echof "DRYRUN: verify SSH, current/profile match, password auth, and activation sudo"))
      (let [ip (utm/ip vm)
            conn (ssh/connection user ip)
            ssh-opts (ssh/trusted-options)]
        (when (empty? ip)
          (abort "Could not resolve IP for UTM VM %s" vm))
        (echof :g "> Waiting for SSH on %s" conn)
        (ssh/wait ssh-opts conn wait-seconds)
        (let [before (remote-trim ssh-opts conn (remote-system-profile))]
          (echof :g "> Rolling back system profile on %s" conn)
          (do? $ ssh ,;ssh-opts ,conn ,(remote-rollback-system-profile-cmd))
          (let [after (remote-trim ssh-opts conn (remote-system-profile))]
            (when (= before after)
              (abort "System profile did not roll back; no previous generation may be available"))
            (echof :g "> Activating rollback %s on %s" after conn)
            (do? $ ssh ,;ssh-opts -t ,conn sudo -n ,(string after "/bin/switch-to-configuration") switch)
            (echof :g "> Updating boot entries for rollback on %s" conn)
            (do? $ ssh ,;ssh-opts ,conn sudo -n ,(string after "/bin/switch-to-configuration") boot)
            (verify-activation ssh-opts conn after)
            (echo :check "Done!")))))))

(defn- utm/generations [ctx]
  (let [vm (ctx :vm)
        user (ctx :user)
        wait-seconds (ctx :wait)]
    (assert |(|(and (not (nil? $)) (> (length $) 0)) vm) "param vm is not set")
    (if (dryrun?)
      (do
        (echof "DRYRUN: resolve VM IP with: hey utm ip %s" vm)
        (echof "DRYRUN: wait up to %d seconds for SSH batch login" wait-seconds)
        (echof "DRYRUN: show /nix/var/nix/profiles/system generations and current/profile paths"))
      (let [remote (utm-ssh-context vm user wait-seconds)
            conn (remote :conn)
            ssh-opts (remote :ssh-opts)
            state (remote-vm-state ssh-opts conn)
            generations (remote-chomp ssh-opts conn (remote-list-system-generations-cmd))]
        (echof "vm: %s" vm)
        (echof "current-system: %s" (state :current))
        (echof "system-profile: %s" (state :profile))
        (echof "rollback-available: %s"
               (if (> (length (string/split "\n" generations)) 1) "yes" "no"))
        (print (format-generations generations))))))

(defn- utm/cleanup-generations [ctx]
  (let [vm (ctx :vm)
        user (ctx :user)
        wait-seconds (ctx :wait)
        keep-generations (ctx :keep-generations)]
    (assert |(|(and (not (nil? $)) (> (length $) 0)) vm) "param vm is not set")
    (if (dryrun?)
      (do
        (echof "DRYRUN: resolve VM IP with: hey utm ip %s" vm)
        (echof "DRYRUN: wait up to %d seconds for SSH batch login" wait-seconds)
        (if keep-generations
          (echof "DRYRUN: keep last %d system generations" keep-generations)
          (echof "DRYRUN: keep remote profile value or fallback to last 3 system generations"))
        (echof "DRYRUN: refresh boot entries and verify activation"))
      (let [remote (utm-ssh-context vm user wait-seconds)
            conn (remote :conn)
            ssh-opts (remote :ssh-opts)
            keep (or keep-generations
                     (vm-policy/manual-keep (remote-vm-image-profile ssh-opts conn) nil))]
        (cleanup-system-generations ssh-opts conn keep)
        (echo :check "Done!")))))

(defn- utm/diff [ctx]
  (let [vm (ctx :vm)
        flake-ref (ctx :flake-ref)
        host (ctx :host)
        user (ctx :user)
        wait-seconds (ctx :wait)
        target (toplevel-target flake-ref host)]
    (assert |(|(and (not (nil? $)) (> (length $) 0)) vm) "param vm is not set")
    (assert |(|(and (not (nil? $)) (> (length $) 0)) host) "param host is not set")
    (if (dryrun?)
      (do
        (echof "DRYRUN: nix build --impure --print-out-paths %s" target)
        (echof "DRYRUN: compare local toplevel with remote current/profile"))
      (let [remote (utm-ssh-context vm user wait-seconds)
            conn (remote :conn)
            ssh-opts (remote :ssh-opts)]
        (echof :g "> Building %s" target)
        (let [out (build-toplevel flake-ref host)
              state (remote-vm-state ssh-opts conn)
              current-match (= out (state :current))
              profile-match (= out (state :profile))]
          (echof "vm: %s" vm)
          (echof "local-toplevel: %s" out)
          (echof "current-system: %s" (state :current))
          (echof "system-profile: %s" (state :profile))
          (echof "current-matches-local: %s" (if current-match "yes" "no"))
          (echof "profile-matches-local: %s" (if profile-match "yes" "no"))
          (echof "status: %s"
                 (if (and current-match profile-match)
                   "up-to-date"
                   "needs-update")))))))

(defn- utm/ssh [ctx remote-args]
  (let [vm (ctx :vm)
        user (ctx :user)]
    (assert |(|(and (not (nil? $)) (> (length $) 0)) vm) "param vm is not set")
    (if (dryrun?)
      (do
        (echof "DRYRUN: resolve VM IP with: hey utm ip %s" vm)
        (echof "DRYRUN: preserve known_hosts and verify the server host key")
        (if (empty? remote-args)
          (echof "DRYRUN: ssh -tt -o StrictHostKeyChecking=ask %s@<ip> <sane login shell>" user)
          (echof "DRYRUN: ssh -o StrictHostKeyChecking=ask %s@<ip> %s"
                 user
                 (ssh/remote-command remote-args))))
      (let [ip (utm/ip vm)
            conn (ssh/connection user ip)
            ssh-opts (ssh/interactive-options)]
        (when (empty? ip)
          (abort "Could not resolve IP for UTM VM %s" vm))
        (exit
          (if (empty? remote-args)
            (execute-clean
              (ssh/args
                (array/concat @["-tt"] ssh-opts)
                conn
                "stty sane 2>/dev/null; exec \"${SHELL:-/run/current-system/sw/bin/zsh}\" -l"))
            (execute-clean (ssh/command-args ssh-opts conn remote-args))))))))

(defn- utm/ssh-slurp [ctx remote-args]
  (let [vm (ctx :vm)
        user (ctx :user)
        ip (utm/ip vm)
        conn (ssh/connection user ip)
        ssh-opts (ssh/trusted-options)]
    (when (empty? ip)
      (abort "Could not resolve IP for UTM VM %s" vm))
    (ssh/slurp-args ssh-opts conn remote-args)))

(defn- current-field [label f]
  (let [[ok result] (protect (f))]
    (if ok
      (echof "%s: %s" label (string/trim (string result)))
      (echof "%s: unavailable" label))))

(defn- utm/current [ctx]
  (let [vm (ctx :vm)
        user (ctx :user)]
    (assert |(|(and (not (nil? $)) (> (length $) 0)) vm) "param vm is not set")
    (if (dryrun?)
      (do
        (echof "DRYRUN: read UTM status for %s" vm)
        (echof "DRYRUN: resolve VM IP with: hey utm ip %s" vm)
        (echof "DRYRUN: query current system, password auth, and activation sudo over SSH"))
      (let [ip (utm/ip vm)
            conn (ssh/connection user ip)
            ssh-opts (ssh/trusted-options)
            sudo-check (remote-activation-sudo)]
        (current-field "vm" (fn [] vm))
        (current-field "status" (fn [] (utm/status vm)))
        (current-field "ip" (fn []
                              (when (or (nil? ip) (empty? ip))
                                (error (string/format "Could not resolve IP for %s" vm)))
                              ip))
        (when (not (empty? ip))
          (current-field "ssh" (fn []
                                 (if (= 0 (ssh/run-quiet ssh-opts conn "true"))
                                   "ok"
                                   "unavailable")))
          (current-field "current-system"
                         (fn [] (ssh/slurp ssh-opts conn (remote-current-system))))
          (current-field "system-profile"
                         (fn [] (ssh/slurp ssh-opts conn (remote-system-profile))))
          (current-field "password-auth"
                         (fn [] (ssh/slurp ssh-opts conn (remote-password-auth))))
          (current-field "activation-sudo"
                         (fn [] (ssh/slurp ssh-opts conn sudo-check))))))))

(defn- doctor-step [label f]
  (let [[ok result] (protect (f))]
    (if ok
      (do
        (echof :check "%s" label)
        true)
      (do
        (echof :error "%s" label)
        (unless (nil? result)
          (echo :err result))
        false))))

(defn- require-non-empty [value message]
  (when (or (nil? value) (empty? value))
    (error message))
  value)

(defn- utm/doctor [ctx]
  (let [vm (ctx :vm)
        user (ctx :user)
        wait-seconds (ctx :wait)]
    (assert |(|(and (not (nil? $)) (> (length $) 0)) vm) "param vm is not set")
    (when (dryrun?)
      (echof "DRYRUN: verify UTM VM %s is registered" vm)
      (echof "DRYRUN: read UTM status for %s" vm)
      (echof "DRYRUN: resolve VM IP with: hey utm ip %s" vm)
      (echof "DRYRUN: wait up to %d seconds for SSH batch login as %s" wait-seconds user)
      (echof "DRYRUN: verify /run/current-system and passwordless activation sudo")
      (break))

    (var ok true)
    (var ip nil)

    (unless (doctor-step "UTM VM is registered"
              (fn []
                (unless (vm/exists? vm)
                  (error (string/format "VM %s does not exist" vm)))
                true))
      (set ok false))

    (unless (doctor-step "UTM status is readable"
              (fn []
                (string/trim (utm/status vm))))
      (set ok false))

    (unless (doctor-step "IP resolves through hey utm ip"
              (fn []
                (set ip (require-non-empty (utm/ip vm)
                          (string/format "Could not resolve IP for %s" vm)))))
      (set ok false))

    (when (and ok (not (empty? ip)))
      (let [conn (ssh/connection user ip)
            ssh-opts (ssh/trusted-options)
            sudo-check "cmd=$(readlink -f /run/current-system/bin/switch-to-configuration); sudo -n -l \"$cmd\" switch >/dev/null"]
        (unless (doctor-step (string/format "SSH becomes ready for %s" conn)
                  (fn []
                    (ssh/wait ssh-opts conn wait-seconds)))
          (set ok false))
        (unless (doctor-step (string/format "SSH batch login works for %s" conn)
                  (fn []
                    (ssh-run-check ssh-opts conn "true")))
          (set ok false))
        (unless (doctor-step "/run/current-system is present"
                  (fn []
                    (ssh-run-check ssh-opts conn "test -e /run/current-system")))
          (set ok false))
        (unless (doctor-step "Passwordless activation sudo rule matches"
                  (fn []
                    (ssh-run-check ssh-opts conn sudo-check)))
          (set ok false))))

    (unless ok
      (exit 1))
    (echo :check "UTM VM doctor passed")))

(defn- utm/check [ctx]
  (let [vm (ctx :vm)]
    (assert |(|(and (not (nil? $)) (> (length $) 0)) vm) "param vm is not set")
    (if (dryrun?)
      (do
        (echof "DRYRUN: hey utm current %s" vm)
        (echof "DRYRUN: hey utm doctor %s" vm)
        (echof "DRYRUN: hey utm ssh %s hey info" vm))
      (do
        (echof :g "> Checking UTM VM %s" vm)
        (utm/current ctx)
        (utm/doctor ctx)
        (echof :g "> Checking remote hey info on %s" vm)
        (print (utm/ssh-slurp ctx @["hey" "info"]))
        (echo :check "UTM VM check passed")))))

(defcmd utm [cmd subcmd & args
             &opts vm [-v --vm vm]
             flake-opt ["-f" "--flake" flake]
             cpu [--cpu cpu {:default 1 :type :number}]
             ram ["--ram" ram {:default 3072 :type :number}]
             user [--user user]
             mode [--mode mode {:default "switch"}]
             wait [--wait wait {:default 180 :type :number}]
             keep-generations [--keep-generations keep-generations {:type :number}]
             scan? [--scan]
             force [--force]
             yes [--yes]
             phases [--phases phases {:default ""}]]

  (merge-into *ctx* @{:vm (or vm (first args))})
  (def resolved-user (or user (flake :user)))
  (when keep-generations (vm-policy/validate-keep keep-generations))
  (when (and scan? (not= subcmd "ip")) (abort "--scan is only supported by hey utm ip"))
  (unless (and (number? wait) (>= wait 0) (< wait math/inf))
    (abort "--wait must be a finite, nonnegative number"))

  # (echof :g "> Executing %s %s" cmd subcmd)
  # (echo :g :json *ctx*)
  # (echo :warn "A warning")
  # (echo :error "An error")
  (case* subcmd
         "ls" (do
                (echo :g "> Enumerating all registered virtual machines...")
                (utm/list))
         "status" (print (utm/status (get *ctx* :vm "")))
         "start" (do
                   (if (dryrun?)
                     (echof "DRYRUN: start UTM VM %s" (get *ctx* :vm ""))
                     (do
                       (echo :g "> Start a virtual machine or resume a suspended virtual machine.")
                       (utm/start (get *ctx* :vm "")))))
         "stop" (do
                  (if (dryrun?)
                    (echof "DRYRUN: stop UTM VM %s" (get *ctx* :vm ""))
                    (do
                      (echo :g "> Stop a virtual machine.")
                      (utm/stop (get *ctx* :vm "")))))
         "create-image" (do
                          (merge-into *ctx*
                                      @{:flake      flake-opt
                                        :flake-ref  (nix/flake-ref flake-opt (path :home))
                                        :cpu        cpu
                                        :ram        ram
                                        :phases     (parse-phases phases)
                                        :mac        (mac/generate vm)
                                        :utm-config (string/format utm-config-tpl cpu ram)
                                        :host       (nix/flake-host flake-opt)
                                        :user       resolved-user
                                        :wait       wait
                                        :force      force
                                        :yes        yes})
                          (utm/create-image *ctx*)
                          (when (and (not (dryrun?)) (get (get *ctx* :phases {}) "start" false))
                            (echo :g "> Start a virtual machine or resume a suspended virtual machine.")
                            (utm/start (get *ctx* :vm "")))
                          (when (and (not (dryrun?)) (get (get *ctx* :phases {}) "doctor" false))
                            (utm/doctor *ctx*)))
         "update" (do
                    (let [vm-name (get *ctx* :vm "")]
                      (merge-into *ctx*
                                  @{:flake (or flake-opt (string ".#" vm-name))
                                    :flake-ref (nix/flake-ref (or flake-opt (string ".#" vm-name)) (path :home))
                                    :host  (nix/flake-host (or flake-opt (string ".#" vm-name)))
                                    :user  resolved-user
                                    :mode  mode
                                    :wait  wait
                                    :keep-generations keep-generations})
                      (utm/update *ctx*)))
         "rollback" (do
                      (merge-into *ctx*
                                  @{:user resolved-user
                                    :wait wait})
                      (utm/rollback *ctx*))
         "generations" (do
                         (merge-into *ctx*
                                     @{:user resolved-user
                                       :wait wait})
                         (utm/generations *ctx*))
         "cleanup-generations" (do
                                  (merge-into *ctx*
                                              @{:user resolved-user
                                                :wait wait
                                                :keep-generations keep-generations})
                                  (utm/cleanup-generations *ctx*))
         "diff" (do
                  (let [vm-name (get *ctx* :vm "")]
                    (merge-into *ctx*
                                @{:flake (or flake-opt (string ".#" vm-name))
                                  :flake-ref (nix/flake-ref (or flake-opt (string ".#" vm-name)) (path :home))
                                  :host  (nix/flake-host (or flake-opt (string ".#" vm-name)))
                                  :user  resolved-user
                                  :wait  wait})
                    (utm/diff *ctx*)))
         "ssh" (do
                 (merge-into *ctx*
                             @{:user resolved-user})
                 (utm/ssh *ctx* (slice args 1)))
         "current" (do
                     (merge-into *ctx*
                                 @{:user resolved-user})
                     (utm/current *ctx*))
         "check" (do
                   (merge-into *ctx*
                               @{:user resolved-user
                                 :wait wait})
                   (utm/check *ctx*))
         "doctor" (do
                    (merge-into *ctx*
                                @{:user resolved-user
                                  :wait wait})
                    (utm/doctor *ctx*))
         "ip" (let [name (vm/validate-name (get *ctx* :vm ""))
                    seconds (min wait 30)]
                (unless (> seconds 0) (abort "--wait must be positive for IP discovery"))
                (if (dryrun?)
                  (echof "DRYRUN: resolve IP for %s (deadline %ss; subnet scan %s)"
                         name (string seconds) (if scan? "enabled, max 8 probes" "disabled"))
                  (print (vm/resolve-ip name scan? seconds))))
         "token" (print (string/join (utm/run (get *ctx* :vm "") "cat /var/lib/rancher/k3s/server/node-token")))
         (abort "Usage: hey utm ls|status|start|stop|create-image|update|rollback|generations|cleanup-generations|diff|ssh|current|check|doctor|ip|token ...")))
