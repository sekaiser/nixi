#!/usr/bin/env janet
# Inspect local SSH process and tunnel state.
#
# SYNOPSIS:
#   ssh ps
#   ssh doctor [--quiet|--verbose]
#
# SUBCOMMANDS:
#   doctor  Detect SSH tunnels, orphaned SSH processes, and zombie SSH processes.
#   ps  List local SSH processes and tunnel-like processes.

(use hey)
(use hey/cmd)

(var *ssh-doctor-verbose* true)

(defn- verbose? []
  *ssh-doctor-verbose*)

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

(defn- command-result [label args &opt fixture-env empty-status validate]
    (if (dryrun?)
      (do
        (echof "DRYRUN: %s" (string/join args " "))
        {:ok true :out ""})
      (let [raw (if-let [fixture (and fixture-env (os/getenv fixture-env))]
                   {:status 0 :out fixture :err ""}
                   (run args 10))
            result ((or validate identity) raw)
            ok (or (= 0 (result :status))
                   (and empty-status (= empty-status (result :status))
                        (empty? (result :out)) (empty? (result :err))))]
        (if ok
          (do
            (success label)
            {:ok true :out (result :out)})
          (do
            (failure (string label " (probe failed)") (if (empty? (result :err)) (result :out) (result :err)))
            {:ok false :out ""})))))

(defn- contains? [haystack needle]
  (and haystack (not (nil? (string/find needle haystack)))))

(defn- nonempty-lines [text]
  (if (or (nil? text) (empty? text))
    @[]
    (filter |(not (empty? (string/trim $))) (string/split "\n" text))))

(def- process-fields process-table/fields)

(defn- process-exec [line]
  (first (string/split " " ((process-fields line) :command))))

(defn- ssh-line? [line]
  (= "ssh" (path/basename (process-exec line))))

(defn- control-master-line? [line]
  (and (contains? line "ControlMaster")
       (not (contains? line "ControlMaster=no"))))

(defn- control-path-line? [line]
  (and (contains? line "ControlPath")
       (not (contains? line "ControlPath=none"))))

(defn- tunnel-line? [line]
  (or (contains? line " -L")
      (contains? line " -R")
      (contains? line " -D")
      (contains? line " -W")
      (contains? line " -N")
      (contains? line " -M")
      (contains? line "LocalForward")
      (contains? line "RemoteForward")
      (contains? line "DynamicForward")
      (control-master-line? line)
      (control-path-line? line)
      (contains? line "ControlPersist")
      (contains? line "ProxyCommand")))

(defn- managed-ssh-line? [line]
  (or (contains? line "/.config/colima/_lima/")
      (contains? line "/.lima/")
      (contains? line " -- sshfs ")))

(defn- zombie-line? [line]
  (contains? ((process-fields line) :stat) "Z"))

(defn- orphan-line? [line]
  (= "1" ((process-fields line) :ppid)))

(defn- print-lines [lines]
  (each line lines
    (echof "  %s" line)))

(defn- unique-values [values]
  (var seen @{})
  (var out @[])
  (each value values
    (when (and value (not (empty? value)) (not (in seen value)))
      (put seen value true)
      (array/push out value)))
  out)

(defn- process-pids [lines]
  (unique-values (map |((process-fields $) :pid) lines)))

(defn- lsof-pids [lines]
  (unique-values
    (map |(get (filter |(not (empty? $)) (string/split " " (string/trim $))) 1) lines)))

(defn- print-remediation [process-lines lsof-lines]
  (let [pids (unique-values [;(process-pids process-lines) ;(lsof-pids lsof-lines)])]
    (unless (empty? pids)
      (let [pid-list (string/join pids " ")]
        (echof "review: ps -fp %s" pid-list)
        (echof "terminate selected: kill %s" pid-list)
        (echof "force only if needed: kill -9 %s" pid-list)))))

(defn- check-cert-file [label kind file]
  (if (dryrun?)
    (do (echof "DRYRUN: validate %s" label) true)
    (try
      (if (not (os/lstat file))
        (success (string label " is not installed"))
        (if (= "configured" ((input/ssh-certificate kind file) "status"))
          (success (string label " signature, type and validity verified"))
          (failure (string label " disappeared during validation"))))
      ([err fib] (failure (string label " validation failed")
                          "Requires a readable regular file (at most 1 MiB) containing a current, correctly signed certificate of the expected type.")))))

(defn- check-host-ca-trust []
  (let [home (os/getenv "HOME")
        known-hosts (path/join home ".ssh/nixi_known_hosts")
        config-file (path/join home ".ssh/config")]
    (if (dryrun?)
      (do (echo "DRYRUN: validate managed SSH host CA trust") true)
      (try
        (if (not (os/lstat known-hosts))
          (success "managed SSH host CA trust file is not installed")
          (let [result (input/ssh-trust known-hosts config-file home)]
            (case (result "status")
              "configured" (success "managed SSH host CA keys and unconditional user-config reference verified")
              "unverified" (failure "managed SSH host CA reference is unverified"
                                    "Conditional trust/Includes, Match or dynamic paths require connection-specific manual verification; no config commands were executed.")
              (failure "SSH user config lacks a verified managed host CA reference"))))
        ([err fib] (failure "managed SSH host CA trust validation failed"
                            "Check public key syntax and readable config/Includes (1 MiB total, at most 64 files, five seconds)."))))))

(defn- check-local-certificates []
  (let [home (os/getenv "HOME")]
    (every? [(check-cert-file "SSH user certificate" "user" (path/join home ".ssh/id_ed25519-cert.pub"))
             (check-host-ca-trust)
             (check-cert-file "SSH host certificate" "host" "/etc/ssh/ssh_host_ed25519_key-cert.pub")])))

(defn- ssh-process-lines []
  (let [result (command-result "process table is readable" process-table/argv nil nil process-table/checked-result)]
    (unless (result :ok) (exit 1))
    (filter ssh-line? (nonempty-lines (result :out)))))

(defn- ssh-ps []
  (when (dryrun?)
    (echof "DRYRUN: %s" (string/join process-table/argv " "))
    (break))
  (let [lines (ssh-process-lines)
        tunnels (filter tunnel-line? lines)]
    (if (empty? lines)
      (success "no ssh processes found")
      (do
        (warning (string/format "%d ssh process(es) found" (length lines)))
        (print-lines lines)))
    (if (empty? tunnels)
      (success "no ssh tunnel-like processes found")
      (do
        (warning (string/format "%d ssh tunnel-like process(es) found" (length tunnels)))
        (print-lines tunnels)))))

(defn- ssh-doctor []
  (var ok true)
  (unless (check-local-certificates) (set ok false))
  (let [ps-result (command-result "process table is readable"
                 process-table/argv
                 "HEY_SSH_DOCTOR_PS" nil process-table/checked-result)
        lsof-result (command-result "listening TCP sockets are readable"
                   @["lsof" "-nP" "-iTCP" "-sTCP:LISTEN"]
                   "HEY_SSH_DOCTOR_LSOF" 1)]
    # A failed probe is unknown state, never evidence of an empty process table.
    (unless (and (ps-result :ok) (lsof-result :ok)) (exit 1))
    (let [ps-out (ps-result :out)
        all-ssh-lines (filter ssh-line? (nonempty-lines ps-out))
        managed-lines (filter managed-ssh-line? all-ssh-lines)
        ssh-lines (filter |(not (managed-ssh-line? $)) all-ssh-lines)
        tunnel-lines (filter tunnel-line? ssh-lines)
        zombie-lines (filter zombie-line? ssh-lines)
        orphan-lines (filter orphan-line? ssh-lines)
        lsof-out (lsof-result :out)
        listen-lines (filter |(contains? $ "ssh") (nonempty-lines lsof-out))]
    (if (empty? all-ssh-lines)
      (success "no ssh processes found")
      (do
        (when (not (empty? managed-lines))
          (success (string/format "%d managed ssh process(es) ignored" (length managed-lines))))
        (if (empty? ssh-lines)
          (success "no unmanaged ssh processes found")
          (do
            (warning (string/format "%d unmanaged ssh process(es) found" (length ssh-lines)))
            (print-lines ssh-lines)))))
    (if (empty? tunnel-lines)
      (success "no ssh tunnel-like processes found")
      (do
        (warning (string/format "%d ssh tunnel-like process(es) found" (length tunnel-lines)))
        (print-lines tunnel-lines)))
    (if (empty? listen-lines)
      (success "no listening TCP ports owned by ssh found")
      (do
        (warning (string/format "%d listening ssh socket(s) found" (length listen-lines)))
        (print-lines listen-lines)))
    (if (empty? orphan-lines)
      (success "no orphaned ssh processes found")
      (do
        (warning (string/format "%d orphaned ssh process(es) found" (length orphan-lines)))
        (print-lines orphan-lines)))
    (if (empty? zombie-lines)
      (success "no zombie ssh processes found")
      (do
        (set ok false)
        (failure (string/format "%d zombie ssh process(es) found" (length zombie-lines)))
        (print-lines zombie-lines)))
    (print-remediation [;tunnel-lines ;orphan-lines ;zombie-lines] listen-lines)))
  (unless ok
    (exit 1)))

(defcmd ssh [_ subcmd & args &opts quiet? --quiet verbose-opt? --verbose]
  (when (and quiet? verbose-opt?)
    (abort "Usage: hey ssh doctor [--quiet|--verbose] | hey ssh ps"))
  (set *ssh-doctor-verbose* (if (= subcmd "doctor") (not quiet?) true))
  (case* subcmd
    "doctor" (if (empty? args)
               (ssh-doctor)
               (abort "Usage: hey ssh doctor [--quiet|--verbose]"))
    "kill-stale" (abort "Automatic SSH termination was removed. Inspect hey ssh ps, then explicitly terminate only reviewed PIDs.")
    "ps" (if (empty? args)
           (ssh-ps)
           (abort "Usage: hey ssh ps"))
    (abort "Usage: hey ssh doctor | hey ssh ps")))
