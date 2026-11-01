#!/usr/bin/env janet

(use judge)
(use hey)

(deftest atom?
  (test (all atom? [true false 0 1 1.5 "string" :keyword 'symbol])
        true)
  (test (all |(not (atom? $))
             [[1 2 3] @[1 2 3] {:foo 1 :bar 2} @{:foo 1 :bar 2} (fn (&)) atom?])
        true))

(deftest array/remove-elt
  (let [values @[1 2 3]]
    (test (array/remove-elt values 3) @[1 2])
    (test (array/remove-elt values 1) @[2])
    (test values @[2])))

(deftest macros
  (deftest with-envvars
    (test (os/getenv "TEST") nil)
    (with-envvars ["TEST" "123"]
      (test (os/getenv "TEST") "123")
      (os/setenv "TEST" "321")
      (test (os/getenv "TEST") "321"))
    (test (os/getenv "TEST") nil))

  (deftest with-umask
    (def original (os/umask 8r022))
    (with-umask 8r077
      (test (os/umask 8r077) 8r077))
    (test (os/umask original) 8r022)))

(deftest string
  (deftest chomp
    (test (string/chomp "foo") "foo")
    (test (string/chomp "foo\n") "foo")
    (test (string/chomp "foo\nbar\n\nbaz") "foo\nbar\n\nbaz"))

  (deftest no-suffix
    (test (string/no-suffix ".janet" "lib.janet") "lib")
    (test (string/no-suffix ".janet" "lib.nix") "lib.nix")
    (test (string/no-suffix "" "lib") "lib"))

  (deftest no-prefix
    (test (string/no-prefix "hey-" "hey-sync") "sync")
    (test (string/no-prefix "hey-" "sync") "sync")
    (test (string/no-prefix "" "sync") "sync")))

(deftest path
  (deftest find
    (test (truthy? (path/find "janet")) true)
    (test (path/find "janet" []) nil)
    (test (path/find "does-not-exist") nil))

  (deftest sibling
    (def dir (path :runtime "test-hey-lib-sibling"))
    (path/rmtree dir)
    (path/mkdirp dir)
    (spit (path/join dir "cmd.janet") "")
    (path/mkdirp (path/join dir "cmd.d"))

    (test (= (string (path/sibling :file (path/join dir "cmd") ".janet" ".zsh"))
             (string (path/join dir "cmd.janet")))
          true)
    (test (= (string (path/sibling :directory (path/join dir "cmd") ".d"))
             (string (path/join dir "cmd.d")))
          true)
    (test (nil? (path/sibling :file (path/join dir "missing") ".janet")) true))

  (deftest files-in
    (def dir (path :runtime "test-hey-lib-files-in"))
    (path/rmtree dir)
    (path/mkdirp dir)
    (spit (path/join dir "a") "")
    (spit (path/join dir "b") "")

    (def files (sort (map string (path/files-in dir))))
    (test (deep= files @[(string (path/join dir "a")) (string (path/join dir "b"))])
          true))

  (deftest mkdirp/rmtree
    (def dir (path :runtime "test-hey-lib-tree"))
    (def nested (path/join dir "a" "b"))
    (path/rmtree dir)
    (test (path/exists? dir) false)
    (path/mkdirp nested)
    (test (path/directory? nested) true)
    (spit (path/join nested "file") "ok")
    (test (path/rmtree dir) nil)
    (test (path/exists? dir) false))

  (deftest abbrev
    (def home (os/getenv "HOME"))
    (test (string (path/abbrev (path/join home "project"))) "~/project")
    (test (string (path/abbrev "/var/tmp/project")) "/var/tmp/project")))
