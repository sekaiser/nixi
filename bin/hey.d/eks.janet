#!/usr/bin/env janet
# Manage AWS EKS access from declarative AWS host config.
#
# SYNOPSIS:
#   eks list
#   eks login [ACCOUNT]
#   eks kubeconfig CLUSTER
#   eks use CLUSTER
#   eks open CLUSTER [default|all|NAMESPACE]
#   eks logs CLUSTER [QUERY] [default|all|NAMESPACE]
#   eks port-forward CLUSTER RESOURCE LOCAL:REMOTE [default|NAMESPACE]
#   eks shell CLUSTER
#   eks status CLUSTER
#   eks credentials CLUSTER
#   eks env CLUSTER
#   eks vpn status|start|restart|logs CLUSTER
#   eks doctor [CLUSTER]
#   eks --bastion VM open CLUSTER
#
# SUBCOMMANDS:
#   list                 List declarative EKS clusters.
#   login                Log in to a configured SAML account or SSO profile.
#   kubeconfig CLUSTER   Refresh kubeconfig for a configured EKS cluster.
#   use CLUSTER          Refresh kubeconfig, select context, and print shell exports.
#   open CLUSTER         Refresh kubeconfig, then open k9s. Optional namespace
#                        mode: default uses configured namespace, all opens all
#                        namespaces, any other value opens that namespace.
#   logs CLUSTER         Stream logs with stern. QUERY defaults to .*.
#   port-forward CLUSTER Forward a pod/service port. With --bastion, creates
#                        an SSH tunnel so LOCAL is reachable from this host.
#   shell CLUSTER        Open a shell with AWS/Kubernetes env for a cluster.
#   status CLUSTER       Show cluster metadata and run lightweight checks.
#   credentials CLUSTER  Show non-secret AWS credential status for a cluster.
#   env CLUSTER          Print shell exports for a configured EKS cluster.
#   vpn ACTION CLUSTER   Manage the configured bastion VPN service.
#   doctor [CLUSTER]     Check local EKS tooling and optional cluster metadata.

(use hey)
(use hey/cmd)
(use hey/ssh)
(use hey/eks/common)
(use hey/eks/auth)
(use hey/eks/diagnostics)
(use hey/eks/transport)

(defn- usage []
  "Usage: hey eks [--bastion VM] [--user USER] list | hey eks [--bastion VM] [--user USER] login [ACCOUNT] | hey eks [--bastion VM] [--user USER] kubeconfig CLUSTER | hey eks [--bastion VM] [--user USER] use CLUSTER | hey eks [--bastion VM] [--user USER] open CLUSTER [default|all|NAMESPACE] | hey eks [--bastion VM] [--user USER] logs CLUSTER [QUERY] [default|all|NAMESPACE] | hey eks [--bastion VM] [--user USER] port-forward CLUSTER RESOURCE LOCAL:REMOTE [default|NAMESPACE] | hey eks [--bastion VM] [--user USER] shell CLUSTER | hey eks [--bastion VM] [--user USER] status CLUSTER | hey eks [--bastion VM] [--user USER] credentials CLUSTER | hey eks [--bastion VM] [--user USER] env CLUSTER | hey eks [--bastion VM] [--user USER] vpn status|start|restart|logs CLUSTER | hey eks [--bastion VM] [--user USER] doctor [CLUSTER]")

(defn- ensure-kubeconfig-dir []
  (unless (dryrun?)
    (try
      (path/mkdirp (kubeconfig-dir))
      ([err fib]
       (abort "Could not create EKS kubeconfig directory: %s" (kubeconfig-dir))))))

(defn- kubeconfig-args [cluster-key cluster]
  # Do not let a previously selected cluster override the new profile's region.
  (let [args @["env" "-u" "AWS_REGION" "-u" "AWS_DEFAULT_REGION"
               "aws" "eks" "update-kubeconfig"
               "--profile" (cluster "profile")
               "--name" (cluster "name")
               "--kubeconfig" (kubeconfig-path cluster-key)]]
    (when-let [region (opt-str (cluster "region"))]
      (array/push args "--region" region))
    (array/push args "--alias" (cluster-context cluster))
    args))

(defn- eks-kubeconfig [cluster-name]
  (let [[key cluster] (find-cluster cluster-name)]
    (ensure-local-bastion-vpn cluster)
    (ensure-kubeconfig-dir)
    (unless (require-command "EKS kubeconfig can be refreshed" (kubeconfig-args key cluster) 30)
      (exit 1))))

(defn- k9s-namespace-args [cluster namespace-mode]
  (case namespace-mode
    "all" ["--all-namespaces"]
    "default" (if-let [namespace (opt-str (cluster "namespace"))]
                ["--namespace" namespace]
                [])
    nil (if-let [namespace (opt-str (cluster "namespace"))]
          ["--namespace" namespace]
          [])
    ["--namespace" namespace-mode]))

(defn- kubernetes-namespace-args [cluster namespace-mode]
  (case namespace-mode
    "all" ["--all-namespaces"]
    "default" (if-let [namespace (opt-str (cluster "namespace"))]
                ["--namespace" namespace]
                [])
    nil (if-let [namespace (opt-str (cluster "namespace"))]
          ["--namespace" namespace]
          [])
    ["--namespace" namespace-mode]))

(defn- eks-open [cluster-name &opt namespace-mode]
  (let [[key cluster] (find-cluster cluster-name)]
    (ensure-local-bastion-vpn cluster)
    (unless (require-command "AWS identity is reachable" (aws-identity-args cluster) 15)
      (abort "Refusing to open k9s because AWS identity preflight failed. Run hey eks login first, then check VPN/network/DNS."))
    (ensure-kubeconfig-dir)
    (unless (require-command "EKS kubeconfig can be refreshed" (kubeconfig-args key cluster) 30)
      (abort "Refusing to open k9s because kubeconfig refresh failed. Check VPN/network/DNS and cluster metadata."))
    (unless (eks-preflight key cluster true)
      (abort "Refusing to open k9s because EKS preflight failed. Check VPN/network/DNS and AWS credentials."))
    (let [args @["env"
                 (string "KUBECONFIG=" (kubeconfig-path key))
                 (string "AWS_PROFILE=" (cluster "profile"))
                 "k9s"]]
      (when-let [context (opt-str (cluster "kubeContext"))]
        (array/push args "--context" context))
      (each arg (k9s-namespace-args cluster namespace-mode)
        (array/push args arg))
      (run args))))

(defn- eks-logs [cluster-name &opt query namespace-mode]
  (let [[key cluster] (find-cluster cluster-name)]
    (ensure-local-bastion-vpn cluster)
    (ensure-kubeconfig-dir)
    (unless (require-command "EKS kubeconfig can be refreshed" (kubeconfig-args key cluster) 30)
      (abort "Refusing to stream logs because kubeconfig refresh failed. Run hey eks login first, then check VPN/network/DNS."))
    (let [args @["env"
                 (string "KUBECONFIG=" (kubeconfig-path key))
                 (string "AWS_PROFILE=" (cluster "profile"))
                 "stern"
                 (or (opt-str query) ".*")
                 "--context" (cluster-context cluster)]]
      (each arg (kubernetes-namespace-args cluster namespace-mode)
        (array/push args arg))
      (run args))))

(defn- eks-port-forward [cluster-name resource mapping &opt namespace-mode]
  (let [[key cluster] (find-cluster cluster-name)]
    (validate-port-forward-args mapping namespace-mode)
    (ensure-local-bastion-vpn cluster)
    (ensure-kubeconfig-dir)
    (unless (require-command "EKS kubeconfig can be refreshed" (kubeconfig-args key cluster) 30)
      (abort "Refusing to port-forward because kubeconfig refresh failed. Run hey eks login first, then check VPN/network/DNS."))
    (let [args @["env"
                 (string "KUBECONFIG=" (kubeconfig-path key))
                 (string "AWS_PROFILE=" (cluster "profile"))
                 "kubectl"
                 "--context" (cluster-context cluster)
                 "port-forward"
                 resource
                 mapping]]
      (each arg (kubernetes-namespace-args cluster namespace-mode)
        (array/push args arg))
      (run args))))

(defn- cluster-environment [key cluster]
  [["AWS_PROFILE" (cluster "profile")]
   ["KUBECONFIG" (kubeconfig-path key)]
   ["KUBE_CONTEXT" (cluster-context cluster)]
   ["EKS_CLUSTER" key]
   ["EKS_CLUSTER_NAME" (cluster "name")]
   ["AWS_REGION" (opt-str (cluster "region"))]
   ["AWS_DEFAULT_REGION" (opt-str (cluster "region"))]
   ["KUBE_NAMESPACE" (opt-str (cluster "namespace"))]])

(defn- eks-shell [cluster-name]
  (let [[key cluster] (find-cluster cluster-name)]
    (ensure-local-bastion-vpn cluster)
    (ensure-kubeconfig-dir)
    (unless (require-command "EKS kubeconfig can be refreshed" (kubeconfig-args key cluster) 30)
      (abort "Refusing to open shell because kubeconfig refresh failed."))
    (let [shell (or (os/getenv "SHELL") "sh")
          values (cluster-environment key cluster)
          args @["env"]]
      # env options must precede assignments on both BSD and GNU systems.
      (each [name value] values
        (unless value (array/push args "-u" name)))
      (each [name value] values
        (when value (array/push args (string name "=" value))))
      (array/push args shell)
      (run args))))

(defn- eks-env [cluster-name]
  (let [[key cluster] (find-cluster cluster-name)
        values (cluster-environment key cluster)]
    (each [name value] values
      (line (if value
              (string "export " name "=" (ssh/shell-quote value))
              (string "unset " name))))))

(defn- eks-use [cluster-name]
  (let [[key cluster] (find-cluster cluster-name)]
    (ensure-local-bastion-vpn cluster)
    (ensure-kubeconfig-dir)
    (unless (require-command "EKS kubeconfig can be refreshed" (kubeconfig-args key cluster) 30)
      (abort "Refusing to select cluster because kubeconfig refresh failed. Run hey eks login first, then check VPN/network/DNS."))
    (unless (require-command "Kubernetes context is selected" (kubectl-use-context-args key cluster) 10)
      (abort "Refusing to select cluster because kubectl could not select the configured context."))
    (eks-env cluster-name)))

(defn- routed-cluster-name [subcmd cluster args]
  (if (= subcmd "vpn")
    (when (valid-vpn-action? cluster)
      (get args 0))
    cluster))

(defn- validate-eks-args [subcmd cluster args]
  (case* subcmd
    "list" (when (or cluster (not (empty? args)))
             (abort "%s" (usage)))
    "login" (when (not (empty? args))
              (abort "Usage: hey eks login [ACCOUNT]"))
    "kubeconfig" (when (or (not cluster) (not (empty? args)))
                   (abort "Usage: hey eks kubeconfig CLUSTER"))
    "use" (when (or (not cluster) (not (empty? args)))
            (abort "Usage: hey eks use CLUSTER"))
    "open" (when (or (not cluster) (> (length args) 1))
             (abort "Usage: hey eks open CLUSTER [default|all|NAMESPACE]"))
    "logs" (when (or (not cluster) (> (length args) 2))
             (abort "Usage: hey eks logs CLUSTER [QUERY] [default|all|NAMESPACE]"))
    "port-forward" (when (or (not cluster) (< (length args) 2) (> (length args) 3))
                     (abort "Usage: hey eks port-forward CLUSTER RESOURCE LOCAL:REMOTE [default|NAMESPACE]"))
    "shell" (when (or (not cluster) (not (empty? args)))
              (abort "Usage: hey eks shell CLUSTER"))
    "status" (when (or (not cluster) (not (empty? args)))
               (abort "Usage: hey eks status CLUSTER"))
    "credentials" (when (or (not cluster) (not (empty? args)))
                    (abort "Usage: hey eks credentials CLUSTER"))
    "env" (when (or (not cluster) (not (empty? args)))
            (abort "Usage: hey eks env CLUSTER"))
    "vpn" (when (or (not cluster) (not= 1 (length args)))
            (abort "Usage: hey eks vpn status|start|restart|logs CLUSTER"))
    "doctor" (when (not (empty? args))
               (abort "Usage: hey eks doctor [CLUSTER]"))
    (abort "%s" (usage))))

(defcmd eks [_ subcmd cluster & args
             &opts bastion [--bastion bastion]
             user [--user user]]
  (validate-eks-args subcmd cluster args)
  (def resolved-user (or user (flake :user)))
  (def chosen-bastion
    (or bastion
        (auto-bastion subcmd (routed-cluster-name subcmd cluster args))))
  (when chosen-bastion
    (let [remote-args @[]]
      (when subcmd
        (array/push remote-args subcmd))
      (when cluster
        (array/push remote-args cluster))
      (each arg args
        (array/push remote-args arg))
      (if (= subcmd "port-forward")
        (bastion-port-forward chosen-bastion resolved-user remote-args)
        (bastion-run chosen-bastion resolved-user remote-args)))
    (break))
  (case* subcmd
    "list" (if (or cluster (not (empty? args)))
             (abort "%s" (usage))
             (eks-list))
    "login" (if (not (empty? args))
              (abort "Usage: hey eks login [ACCOUNT]")
              (eks-login cluster))
    "kubeconfig" (if (or (not cluster) (not (empty? args)))
                   (abort "Usage: hey eks kubeconfig CLUSTER")
                   (eks-kubeconfig cluster))
    "use" (if (or (not cluster) (not (empty? args)))
            (abort "Usage: hey eks use CLUSTER")
            (eks-use cluster))
    "open" (if (or (not cluster) (> (length args) 1))
             (abort "Usage: hey eks open CLUSTER [default|all|NAMESPACE]")
             (eks-open cluster (get args 0)))
    "logs" (if (or (not cluster) (> (length args) 2))
             (abort "Usage: hey eks logs CLUSTER [QUERY] [default|all|NAMESPACE]")
             (eks-logs cluster (get args 0) (get args 1)))
    "port-forward" (if (or (not cluster) (< (length args) 2) (> (length args) 3))
                     (abort "Usage: hey eks port-forward CLUSTER RESOURCE LOCAL:REMOTE [default|NAMESPACE]")
                     (eks-port-forward cluster (get args 0) (get args 1) (get args 2)))
    "shell" (if (or (not cluster) (not (empty? args)))
              (abort "Usage: hey eks shell CLUSTER")
              (eks-shell cluster))
    "status" (if (or (not cluster) (not (empty? args)))
               (abort "Usage: hey eks status CLUSTER")
               (eks-status cluster))
    "credentials" (if (or (not cluster) (not (empty? args)))
                    (abort "Usage: hey eks credentials CLUSTER")
                    (eks-credentials cluster))
    "env" (if (or (not cluster) (not (empty? args)))
            (abort "Usage: hey eks env CLUSTER")
            (eks-env cluster))
    "vpn" (if (or (not cluster) (not= 1 (length args)))
            (abort "Usage: hey eks vpn status|start|restart|logs CLUSTER")
            (eks-vpn cluster (get args 0)))
    "doctor" (if (not (empty? args))
               (abort "Usage: hey eks doctor [CLUSTER]")
               (eks-doctor cluster))
    (abort "%s" (usage))))
