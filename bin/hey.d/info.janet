#!/usr/bin/env janet
# Inspect flake metadata, IP addresses, or Git repository metadata.
#
# SYNOPSIS:
#   info [-r] [KEYS...]
#   info [-r] ip [-w]
#   info [user/repo|https://url/to/git/repo]

(use hey)
(use hey/cmd)
(import spork/json)
(import hey/process)

(defn- command-output [args]
  (string/trim (process/output args 30)))

(defn- default-interface-darwin []
  (first
    (keep |(when-let [match (peg/match '(* (some :s) "interface:" (some :s) (capture (some (if-not :s 1)))) $)]
             (first match))
          (string/split "\n" (command-output @["route" "-n" "get" "default"])))))

(defn- linux-route-source-ip [route]
  (let [source (get (first (json/decode route)) "prefsrc")]
    (when (and (string? source) (not (empty? source)))
      source)))

(defn- local-ip []
  (case (command-output @["uname"])
    "Darwin" (if-let [interface (default-interface-darwin)]
               (command-output @["ipconfig" "getifaddr" interface])
               (abort "Could not determine default network interface"))
    # Ask the kernel to resolve an outbound IPv4 route, including its chosen
    # source. This performs a routing lookup only; it sends no packets.
    (or (linux-route-source-ip (command-output @["ip" "-j" "-4" "route" "get" "1.1.1.1"]))
        (abort "Could not determine source IPv4 address from resolved route"))))

(defn- ip [wan? & args]
  (if wan?
    (command-output @["dig" "+short" "myip.opendns.com" "@resolver1.opendns.com"])
    (local-ip)))

(defn- ip-dryrun [wan?]
  (if wan?
    (echof "DRYRUN: dig +short myip.opendns.com @resolver1.opendns.com")
    (do
      (echof "DRYRUN: Darwin local IP via route -n get default and ipconfig getifaddr <interface>")
      (echof "DRYRUN: Linux local IP via ip -j -4 route get 1.1.1.1"))))

(defn- repo [url]
  (let [args @["nix-prefetch-git" "--quiet" url]]
    (if (dryrun?)
      (echof "DRYRUN: %s" (string/join args " "))
      (let [status (execute-clean args)]
        (unless (= 0 status)
          (exit status))))))

(defcmd info [_ & args &opts raw? -r wan? -w]
  (let [format (if raw? :raw :json)]
    (var cmd (or (first args) ""))
    (cond (= cmd "ip")
          (if (dryrun?)
            (ip-dryrun wan?)
            (echo format (ip wan? ;(slice args 1))))

          (= cmd "commands")
          (echo format (flake/commands ;(map keyword (slice args 1))))

          (peg/match '(* "http" (? "s") "://") cmd)
          (repo cmd)

          (set cmd (peg/match {:seg '(capture (some (+ :w (set "_-.@"))))
                               :main '(* :seg "/" :seg)}
                              cmd))
          (repo (string "https://github.com/" (in cmd 0) "/" (in cmd 1)))

          (echo format (flake/info ;(map keyword args))))))
