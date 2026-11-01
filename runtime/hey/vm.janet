(import spork/path)
(import ./process)
(use ./lib)
(use sh)

(defn- split-into-chunks [s chunk-size]
  (var result @[])
  (var i 0)
  (while (< i (length s))
    (array/push result (string/slice s i (min (+ i chunk-size) (length s))))
    (set i (+ i chunk-size)))
  result)

(defn- remaining [deadline]
  (if deadline (max 0 (- deadline (os/clock :monotonic))) 30))

(defn- command-output [args &opt deadline]
  (let [seconds (remaining deadline)]
    (when (> seconds 0)
      (ignore-errors
        (let [out (string/trim (process/output args seconds))]
          (unless (empty? out) out))))))

(defn mac/generate [vm-name &opt deadline]
  (when-let [output (command-output @["md5" "-s" (string vm-name)] deadline)]
   (let [digest (last (string/split " " output))
        suffix (string/join (split-into-chunks (string/slice digest 0 10) 2) ":")]
    (string "02:" suffix))))

(defn- readable-file? [file]
  (when (= :file (os/stat file :mode))
    (if-let [f (ignore-errors (os/open file :r))]
      (do
        (:close f)
        true))))

(defn- mac-normalize-for-arp [mac]
  (string/join
    (map |(if (and (= 2 (length $)) (= "0" (string/slice $ 0 1)))
            (string/slice $ 1)
            $)
         (string/split ":" (string mac)))
    ":"))

(defn ip/link-local? [ip]
  (string/has-prefix? "169.254." (string/trim ip)))

(defn- arp-ip [mac &opt deadline]
  (let [normalized (mac-normalize-for-arp mac)]
    (when-let [out (command-output @["arp" "-a"] deadline)]
      (first
        (keep
          (fn [line]
            (when (string/find normalized line)
              (when-let [start (string/find "(" line)
                         end (string/find ")" line)]
                (when (< start end)
                  (let [ip (string/slice line (+ start 1) end)]
                    (unless (ip/link-local? ip)
                      ip))))))
          (string/split "\n" out))))))

(defn- plist-mac [plist]
  (when (readable-file? plist)
    (let [lines (string/split "\n" (slurp plist))]
      (var result nil)
      (loop [i :range [0 (- (length lines) 1)]]
        (when (string/find "<key>MacAddress</key>" (lines i))
          (let [line (lines (+ i 1))
                start (string/find "<string>" line)
                end (string/find "</string>" line)]
            (when (and (not (nil? start)) (not (nil? end)) (< start end))
              (set result (string/slice line (+ start 8) end))
              (break)))))
      result)))

(defn- utm-applescript-mac [vm &opt deadline]
  (command-output @["osascript"
                    "-e"
                    (string/format "tell application \"UTM\" to get address of network interface 0 of virtual machine %q" vm)] deadline))

(defn- utm-applescript-host-interface [vm &opt deadline]
  (command-output @["osascript"
                    "-e"
                    (string/format "tell application \"UTM\" to get host interface of network interface 0 of virtual machine %q" vm)] deadline))

(defn- utmctl-ip [vm &opt deadline]
  (when-let [ip (command-output @["utmctl" "ip-address" vm] deadline)]
    (unless (ip/link-local? ip)
      ip)))

(defn- nonempty-lines [text]
  (filter |(not (empty? $))
          (map string/trim (string/split "\n" (or text "")))))

(defn- split-fields [line]
  (filter |(not (empty? $))
          (string/split " " (string/trim line))))

(defn- utmctl-list-fields []
  (when-let [out (command-output @["utmctl" "list"])]
    (map split-fields (slice (nonempty-lines out) 1))))

(defn- utmctl-list-name [fields]
  (in fields 2))

(defn- numeric-suffix [prefix name]
  (let [needle (string prefix "-")]
    (when (string/has-prefix? needle name)
      (let [suffix (string/slice name (length needle))]
        (when (peg/match '(* :d+ -1) suffix)
          (scan-number suffix))))))

(defn- vm-name-rank [base name]
  (or (numeric-suffix base name)
      (if (= base name) 0 -1)))

(defn- matching-utm-names [vm]
  (->> (utmctl-list-fields)
       (keep utmctl-list-name)
       (filter |(>= (vm-name-rank vm $) 0))
       (sort-by |(- (vm-name-rank vm $)))))

(defn- ip-prefix24 [ip]
  (let [parts (string/split "." (string/trim ip))]
    (when (and (= (length parts) 4)
               (every? (map |(and (peg/match '(* :d+ -1) $)
                                 (<= 0 (scan-number $) 255)) parts)))
      (string/join (slice parts 0 3) "."))))

(defn- ping-prefix24 [prefix deadline]
  # At most eight supervised probes; every worker shares the caller's deadline.
  # No unbounded os/spawn fan-out and no independent per-host 30s timeout.
  (var next 1)
  (defn worker []
    (while (and (< next 255) (> (remaining deadline) 0))
      (let [i next]
        (++ next)
        (ignore-errors
          (process/probe @["ping" "-n" "-c" "1" "-W" "200" (string prefix "." i)]
                         (min 1 (remaining deadline)) 4096)))))
  (def workers @[])
  (repeat 8 (array/push workers worker))
  (ev/go-gather workers))

(defn- refresh-interface-arp [iface deadline]
  (when-let [ip (command-output @["ipconfig" "getifaddr" iface] deadline)]
    (when-let [prefix (ip-prefix24 ip)]
      (ping-prefix24 prefix deadline))))

(defn- vm-ip [vm plist deadline]
  (or (utmctl-ip vm deadline)
      (when-let [mac (mac/generate vm deadline)] (arp-ip mac deadline))
      (when-let [mac (plist-mac plist)] (arp-ip mac deadline))
      (when-let [mac (utm-applescript-mac vm deadline)] (arp-ip mac deadline))))

(defn- ps-pid-command [line]
  (let [trimmed (string/trim line)
        space (string/find " " trimmed)]
    (when space
      [(string/slice trimmed 0 space) (string/trim (string/slice trimmed (+ space 1)))])))

(defn utm/pid []
  (first
    (keep
      (fn [line]
        (when-let [[pid command] (ps-pid-command line)]
          (when (string/find "/UTM" command)
            pid)))
      (string/split "\n" (or (command-output @["ps" "ax" "-o" "pid,command"]) "")))))

(defn utm/open? [] (not (nil? (utm/pid))))

(defn utm/open [] ($ open "/Applications/UTM.app"))

(def- delete-vm-tpl ``
      on run argv
        set vm_name to item 1 of argv
        tell application "UTM"
            set matching_vms to every virtual machine whose name is vm_name
            repeat with vm in matching_vms
                delete vm
            end repeat
        end tell
      end run``)

(defn utm/list []
  (os/execute @("utmctl" "list") :px))

(defn utm/status [vm]
  ($< utmctl status ,vm))

(defn utm/started? [vm]
  (string/has-prefix? "started" (utm/status vm)))

(defn utm/start [vm]
  (os/execute @("utmctl" "start" vm) :px))

(defn utm/stop [vm]
  (os/execute @("utmctl" "stop" vm) :px))

(defn utm/delete [vm]
  ($ osascript -e (string delete-vm-tpl) (string vm)))

(defn utm/find [vm]
  (let [[ok? names] (protect (matching-utm-names vm))]
    (when ok? (first names))))

(defn vm/exists? [patt &opt timeout]
  # A failed query is not evidence that a VM has disappeared.
  (let [lines (nonempty-lines (process/output @["utmctl" "list"] (or timeout 30)))]
    (when (empty? lines) (error "UTM returned an empty VM listing"))
    (truthy? (find |(= patt (string/join (slice (split-fields $) 2) " "))
                  (slice lines 1)))))

(defn vm/validate-name [name]
  (unless (and (string? name) (not (empty? name))
               (not (index-of name ["." ".."])) (not (string/find "/" name)))
    (error "VM name must be a nonempty filename, without '/' or dot-directory names"))
  name)

(defn vm/resolve-ip [name &opt scan? seconds]
  (vm/validate-name name)
  (default seconds 30)
  (unless (and (number? seconds) (> seconds 0) (< seconds math/inf))
    (error "IP discovery timeout must be a finite positive number"))
  (let [deadline (+ (os/clock :monotonic) seconds)
        plist (path/join (os/getenv "HOME") "Library/Containers/com.utmapp.UTM/Data/Documents"
                         (string name ".utm") "config.plist")]
    (var scanned? false)
    (var ip nil)
    (while (and (nil? ip) (> (remaining deadline) 0))
      (set ip (vm-ip name plist deadline))
      (when (and (nil? ip) scan? (not scanned?))
        (set scanned? true)
        (when-let [iface (utm-applescript-host-interface name deadline)]
          (refresh-interface-arp iface deadline)))
      (when (nil? ip) (os/sleep (min 1 (remaining deadline)))))
    (or ip (errorf "Could not resolve IP for UTM VM %s within %s seconds. Start the VM and check networking; --scan explicitly permits a bounded local /24 ping sweep."
                   name (string seconds)))))

(defn vm/wait-for [name exists? &opt seconds]
  (default seconds 30)
  (unless (and (number? seconds) (>= seconds 0) (< seconds math/inf))
    (error "VM wait timeout must be a finite nonnegative number"))
  (let [deadline (+ (os/clock :monotonic) seconds)]
    (forever
      (def remaining (- deadline (os/clock :monotonic)))
      (when (<= remaining 0)
        (errorf "Timed out waiting for VM %s to be %s; inspect UTM before retrying."
                name (if exists? "registered" "deleted")))
      (when (= exists? (vm/exists? name remaining)) (break))
      (os/sleep (max 0 (min 1 (- deadline (os/clock :monotonic))))))))

(defn cleanup-temp-files [files]
  (each file files
    (when (os/stat file)
      (os/rm file))))

(defn vm/update-plist [plist patch]
  # Reserve a private directory on the same filesystem as the destination.
  # Nothing touches the live configuration until every conversion validates.
  (unless (= :file (os/lstat plist :mode))
    (errorf "Expected a regular VM configuration file: %s" plist))
  (let [dir (string/trim ($< mktemp -d (path/join (path/dirname plist) ".nixi-plist.XXXXXXXXXX")))
        original (path/join dir "original.json")
        changes (path/join dir "patch.json")
        replacement (path/join dir "config.plist")]
    (defer (path/rmtree dir)
      (with [out (file/open changes :w)]
        ($ nix eval --json --expr (string patch) >(do out)))
      ($ plutil -convert json -o (string original) (string plist))
      (with [out (file/open replacement :w)]
        ($ jq -s "reduce .[] as $item ({}; . * $item)" (string original) (string changes) >(do out)))
      ($ plutil -convert xml1 (string replacement))
      ($ plutil -lint (string replacement))
      (os/chmod replacement (os/stat plist :int-permissions))
      (os/rename replacement plist))))

(defn vm/configure [cmd & args]
  (def vm-name (get args 0))
  (def patch (get args 1))
  (def- utm-data-dir (string/format "%s/Library/Containers/com.utmapp.UTM/Data/Documents" (os/getenv "HOME")))
  (def vm-dir (string utm-data-dir "/" vm-name ".utm"))
  (def plist (string vm-dir "/config.plist"))
  (case* cmd
    "show" ($ plutil -convert json -o - (string plist) | jq .)
    "mac" (print (or (plist-mac plist) (string/trim (mac/generate vm-name))))
    "ip" (vm/resolve-ip vm-name)
    "update" (vm/update-plist plist patch)))

(defn vm/create [{:vm vm :image image :mac mac :utm-config utm-config :vm-config vm-config}]
  ($ osascript -e (string vm-config) (string vm) (string mac) (string image))
  (vm/configure "update" vm utm-config)
  (os/sleep 1))
