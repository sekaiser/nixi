# Explicit/local VPN lifecycle and bastion SSH routing.
(use hey)
(use hey/ssh)
(use hey/eks/common)

(defn- run-silent [args]
  ((command-result args nil) :status))

(defn- local-change-vpn [service action]
  (run-silent @["sudo" "-n" "/run/current-system/sw/bin/systemctl" "reset-failed" service])
  (let [status (os/execute @["sudo" "-n" "/run/current-system/sw/bin/systemctl" action service] :p {:out stderr})]
    (unless (= 0 status)
      (abort "VPN service %s did not %s on %s" service action (current-host))))
  (os/sleep 2)
  (if (= 0 (run-silent @["systemctl" "is-active" "--quiet" service]))
    0
    (do
      (os/execute @["systemctl" "--no-pager" "--full" "status" service] :p {:out stderr})
      (os/execute @["journalctl" "-u" service "-n" "30" "--no-pager"] :p {:out stderr})
      1)))

(defn- local-start-vpn [service]
  (if (dryrun?)
    (file/write stdout (string "DRYRUN: sudo -n /run/current-system/sw/bin/systemctl reset-failed " service " && sudo -n /run/current-system/sw/bin/systemctl start " service " && wait until active\n"))
    (let [status (local-change-vpn service "start")]
      (unless (= 0 status)
        (abort "VPN service %s did not become active on %s" service (current-host))))))

(defn ensure-local-bastion-vpn [cluster]
  (when (local-bastion-for-cluster? cluster)
    (when-let [service (opt-str (cluster "vpnService"))]
      (file/write stderr (string "> Running on bastion " (current-host) "; using local VPN service " service "\n"))
      (local-start-vpn service))))

(defn- local-vpn-status [service]
  (run @["systemctl" "--no-pager" "--full" "status" service]))

(defn- local-vpn-logs [service]
  (run @["journalctl" "-u" service "-n" "80" "--no-pager"]))

(defn- local-restart-vpn [service]
  (if (dryrun?)
    (file/write stdout (string "DRYRUN: sudo -n /run/current-system/sw/bin/systemctl reset-failed " service " && sudo -n /run/current-system/sw/bin/systemctl restart " service " && wait until active\n"))
    (let [status (local-change-vpn service "restart")]
      (unless (= 0 status)
        (abort "VPN service %s did not become active on %s" service (current-host))))))

(defn eks-vpn [action cluster-name]
  (let [[_ cluster] (find-cluster cluster-name)
        service (cluster-vpn-service cluster)]
    (case* action
      "status" (local-vpn-status service)
      "start" (local-start-vpn service)
      "restart" (local-restart-vpn service)
      "logs" (local-vpn-logs service)
      (abort "Usage: hey eks vpn status|start|restart|logs CLUSTER"))))

(defn- bastion-ip [vm]
  (string/trim ($< ,(path :bin "hey") utm ip ,vm)))

(defn- bastion-needs-vpn? [remote-args]
  (not (nil? (index-of (get remote-args 0)
                       ["open" "logs" "port-forward" "kubeconfig" "use" "shell"]))))

(defn- bastion-doctor? [remote-args]
  (and (= "doctor" (get remote-args 0))
       (not (nil? (get remote-args 1)))))

(defn- bastion-needs-tty? [remote-args]
  (not (nil? (index-of (get remote-args 0) ["login" "open" "shell" "logs" "port-forward"]))))

(defn- bastion-ssh-options []
  @[;(ssh/trusted-options)
    "-o" "LogLevel=ERROR"
    "-o" "ControlMaster=no"
    "-o" "ControlPath=none"
    "-o" "ExitOnForwardFailure=yes"
    "-o" "ServerAliveInterval=15"
    "-o" "ServerAliveCountMax=2"])

(defn- bastion-ssh-options-text []
  (string/join (bastion-ssh-options) " "))

(defn- bastion-ssh-args [user ip remote-cmd &opt extra-opts]
  (let [args @["ssh"]]
    (each opt (or extra-opts @[])
      (array/push args opt))
    (each opt (bastion-ssh-options)
      (array/push args opt))
    (array/push args (string user "@" ip))
    (array/push args remote-cmd)
    args))

(defn- bastion-start-vpn [user ip service]
  (let [quoted-service (ssh/shell-quote service)
        script (string
                 "exec 1>&2; "
                 "sudo -n /run/current-system/sw/bin/systemctl reset-failed " quoted-service " >/dev/null 2>&1 || true; "
                 "sudo -n /run/current-system/sw/bin/systemctl start " quoted-service "; "
                 "sleep 2; "
                 "if systemctl is-active --quiet " quoted-service "; then exit 0; fi; "
                 "systemctl --no-pager --full status " quoted-service "; "
                 "journalctl -u " quoted-service " -n 30 --no-pager; "
                 "exit 1")
        args (bastion-ssh-args user ip script @["-o" "BatchMode=yes"])
        status (execute-clean args)]
    (unless (= 0 status)
      (abort "Bastion VPN service %s did not become active on %s@%s" service user ip))
    (success (string "bastion VPN service is active: " service))))

(defn- bastion-vpn-service [remote-args]
  (let [cluster-name (get remote-args 1)]
    (if cluster-name
      (let [[_ cluster] (find-cluster cluster-name)]
        (cluster-vpn-service cluster))
      "openvpn-eks.service")))

(defn bastion-run [vm user remote-args]
  (if (dryrun?)
    (do
      (file/write stdout (string "DRYRUN: resolve bastion IP with: hey utm ip " vm "\n"))
      (when (bastion-doctor? remote-args)
        (file/write stdout (string "DRYRUN: ssh -o BatchMode=yes -o ConnectTimeout=10 "
                                   (bastion-ssh-options-text) " " user "@<ip> true\n")))
      (when (bastion-needs-vpn? remote-args)
        (let [service (bastion-vpn-service remote-args)]
          (file/write stdout (string "DRYRUN: ssh -o BatchMode=yes "
                                     (bastion-ssh-options-text)
                                     " <bastion> sudo -n /run/current-system/sw/bin/systemctl reset-failed "
                                     service " && sudo -n /run/current-system/sw/bin/systemctl start "
                                     service " && wait until active\n"))))
      (file/write stdout
                  (string "DRYRUN: ssh "
                          (if (bastion-needs-tty? remote-args) "-t " "")
                          (bastion-ssh-options-text) " "
                          user "@<ip> " (ssh/remote-command ["hey" "eks" ;remote-args]) "\n")))
    (let [ip (bastion-ip vm)]
      (when (empty? ip)
        (abort "Could not resolve IP for bastion VM %s" vm))
      (file/write stderr (string "> Running on " (current-host) "; routing EKS command through bastion " vm "\n"))
      (when (bastion-doctor? remote-args)
        (success (string "bastion IP resolves: " vm " -> " ip))
        (unless (require-command "bastion SSH batch login works"
                  (bastion-ssh-args user ip "true" @["-o" "BatchMode=yes"
                                                      "-o" "ConnectTimeout=10"])
                  15)
          (exit 1)))
      (when (bastion-needs-vpn? remote-args)
        (bastion-start-vpn user ip (bastion-vpn-service remote-args)))
      (let [opts @[]]
        (when (bastion-needs-tty? remote-args)
          (array/push opts "-t"))
        (let [status (execute-clean
                       (ssh/command-args [;opts ;(bastion-ssh-options)]
                         (ssh/connection user ip) ["hey" "eks" ;remote-args]))]
          (unless (= 0 status)
            (exit status)))))))

(defn bastion-port-forward [vm user remote-args]
  (let [mapping (get remote-args 3)
        namespace-mode (get remote-args 4)
        local-port (port-forward-local-port mapping)]
    (validate-port-forward-args mapping namespace-mode)
    (if (dryrun?)
      (do
        (file/write stdout (string "DRYRUN: resolve bastion IP with: hey utm ip " vm "\n"))
        (let [service (bastion-vpn-service remote-args)]
          (file/write stdout (string "DRYRUN: ssh -o BatchMode=yes "
                                     (bastion-ssh-options-text)
                                     " <bastion> sudo -n /run/current-system/sw/bin/systemctl reset-failed "
                                     service " && sudo -n /run/current-system/sw/bin/systemctl start "
                                     service " && wait until active\n")))
        (file/write stdout
                    (string "DRYRUN: ssh -t -L 127.0.0.1:" local-port ":127.0.0.1:" local-port
                            " " (bastion-ssh-options-text) " "
                            user "@<ip> " (ssh/remote-command ["hey" "eks" ;remote-args]) "\n")))
      (let [ip (bastion-ip vm)]
        (when (empty? ip)
          (abort "Could not resolve IP for bastion VM %s" vm))
        (line (string "> Running on " (current-host) "; routing EKS port-forward through bastion " vm))
        (bastion-start-vpn user ip (bastion-vpn-service remote-args))
        (let [opts @["-t" "-L" (string "127.0.0.1:" local-port ":127.0.0.1:" local-port)
                     ;(bastion-ssh-options)]]
          (let [status (execute-clean
                         (ssh/command-args opts (ssh/connection user ip)
                           ["hey" "eks" ;remote-args]))]
            (unless (= 0 status)
              (exit status))))))))

(defn auto-bastion [subcmd cluster-name]
  (when (and subcmd cluster-name
             (not= subcmd "login")
             (not= subcmd "list"))
    (let [[_ cluster] (find-cluster cluster-name)
          bastion (opt-str (cluster "bastion"))]
      (when (and bastion (not (empty? bastion)) (not= bastion (current-host)))
        bastion))))
