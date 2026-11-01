#!/usr/bin/env janet
# Trigger an event.
#
# Hooks include user scripts in $XDG_DATA_HOME/hey/hooks.d/HOOK.d/.
#
# SYNOPSIS:
#   hook HOOK [ARGS...]
#
# RECOGNIZED HOOKS:
#   on-startup
#   on-idle [--{dim,dpms,lock,sleep,resume}]
#   on-sleep
#   on-wakeup
#   on-lock
#   on-unlock
#   on-battery [charging|discharging|*] [ARGS...]
#   on-discharging

(use hey)
(use hey/cmd)
(import hey/vars)

(def- *vars* (vars/new (:dir vars/temp :hook)))

(defn- hooks [hook args &opt global?]
  (let [wmdir (ignore-errors (path (if global? :wm :wm*) "hooks"))
        wm-hooks (if wmdir
                   [(resolve wmdir "all" (string "--" hook) ;args)
                    (resolve wmdir hook ;args)]
                   [])]
    (each f [;wm-hooks
             (resolve (path :host "hooks") hook ;args)
             ;(map |[$ ;args]
                   (or (ignore-errors
                        (sort (path/files-in (path :data "hooks.d" (string hook ".d")))))
                       []))]
      (when (and f (path/executable? (first f)))
        (yield f)))))

(defn- trigger-hooks [hook args global?]
  (var c 0)
  (each cmd (coro (hooks hook args global?))
    (log "Hook: %s" (path/abbrev (first cmd)))
    (echof :g "Running %s..." (path/basename (first cmd)))
    (do? $ ,;cmd)
    (++ c))
  (echof :pass "Triggered %d hook(s) for: %q" c [hook ;args]))

(defcmd hook [_ hook & args &opts global? -g force? -f verbose? -v]
  (let [hash [hook (truthy? global?) ;args]]
    (unless hook
      (abort "Usage: hey hook HOOK [ARGS...]"))
    (if (dryrun?)
      (trigger-hooks hook args global?)
      (os/with-lock (path :runtime "hook.lock")  # don't clobber hooks
        (when (and (not force?) (deep= (:get *vars* :last) hash))
          (abort "Redundant hook triggered: %q" hash))
        # Invalidate the previous completion before attempting even a forced
        # retry. A failed attempt must remain retryable.
        (:set *vars* :last nil)
        (trigger-hooks hook args global?)
        (:set *vars* :last hash)))))
