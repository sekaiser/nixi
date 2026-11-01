#!/usr/bin/env janet
# Read and write hey variables.
#
# SYNOPSIS:
#   vars [ls]
#   vars get KEY
#   vars set KEY VALUE
#
# OPTIONS:
#   -g
#     Use the global variable store.

(use hey)
(use hey/cmd)
(import hey/vars)

(defcmd vars [_ cmd & args &opts global? -g]
  (echo ;(case cmd
          "get" (if (= (length args) 1)
                  (let [key (first args)]
                    [(vars/get key global?)])
                  (abort "Usage: hey vars get KEY"))
          "set" (if (= (length args) 2)
                  (let [key (in args 0)
                        value (get args 1)]
                    [(vars/set key value global?)])
                  (abort "Usage: hey vars set KEY VALUE"))
          "ls"  (if (empty? args)
                  (vars/list global?)
                  (abort "Usage: hey vars [ls|get|set]"))
          nil   (if (empty? args)
                  (vars/list global?)
                  (abort "Usage: hey vars [ls|get|set]"))
          (abort "Usage: hey vars [ls|get|set]"))))
