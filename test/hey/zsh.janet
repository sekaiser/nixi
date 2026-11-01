#!/usr/bin/env janet

(use judge)
(use sh)
(import hey)

(def- zsh-loader
  (string "fpath=(" (hey/path :runtime-lib "zsh") " $fpath); "
          "autoload -Uz hey.log hey.echo hey.error hey.abort; "
          "script=$1; shift; source $script"))

(defmacro zsh [& args]
  ~(,(first args) zsh -fc ,zsh-loader zsh ,(hey/path :runtime-lib "zsh" (get args 1)) ,;(slice args 2)))

(def- null (file/open "/dev/null"))

(deftest hey.requires
  (test (zsh $? hey.requires zsh bash sh) true)
  (test (zsh $? hey.requires zsh bash doesnotexist > [stderr null]) false)
  (test (zsh $? hey.requires doesnotexist > [stderr null]) false))

(deftest hey.do
  (test (zsh $<_ hey.do echo 10) "10")
  (hey/with-envvars ["HEYDRYRUN" "1"]
    (let [out @"" err @""]
      (zsh $<_ hey.do echo 10 > ,out > [stderr err])
      (test (deep-not= err @"") true)
      (test out @""))))
