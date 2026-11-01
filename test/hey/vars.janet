#!/usr/bin/env janet

(use judge)
(use hey)
(import hey/vars)

(def- vars (vars/new (:dir vars/temp :test)))

(defn- setup []
  (path/rmtree (:dir vars)))  # Always start from scratch

(deftest get/set
  (setup)
  (test (:get vars :does-not-exist) nil)
  (test (:set vars :key 123) 123)
  (test (:get vars :key) 123)
  (test (:set vars :key nil) :key))

(deftest list
  (setup)
  (:set vars :foo 1)
  (:set vars :bar 2)
  (:set vars :baz 3)
  (test (length (:list vars)) 3)
  (:clear vars)
  (test (length (:list vars)) 0))

(deftest cache
  (setup)
  (var calls 0)
  (defn value []
    (set calls (+ calls 1))
    (string "value-" calls))

  (test (:cache vars :key value) "value-1")
  (test (:cache vars :key value) "value-1")
  (test calls 1)
  (test (:cache vars :key value true) "value-2")
  (test calls 2))

(deftest confined-keys
  (setup)
  (each key ["" "." ".." "../escaped" "/absolute" "nested/key" "back\\slash" "null\0byte" [:nested :key]]
    (test (first (protect (:set vars key "value"))) false)
    (test (first (protect (:get vars key))) false))
  (test (os/lstat (:dir vars)) nil))

(deftest dry-run-preserves-state
  (setup)
  (with-dyns [*dryrun* true]
    (:set vars :key "not written")
    (test (os/lstat (:dir vars)) nil))
  (:set vars :key "original")
  (with-dyns [*dryrun* true]
    (:set vars :key "replacement")
    (:set vars :key nil)
    (:clear vars))
  (test (:get vars :key) "original"))

(deftest failed-replacement-cleans-staging
  (setup)
  (path/mkdirp (:file vars :blocked))
  (spit (path/join (:file vars :blocked) "sentinel") "keep")
  (test (first (protect (:set vars :blocked "replacement"))) false)
  (test (string (slurp (path/join (:file vars :blocked) "sentinel"))) "keep")
  (test (os/dir (:dir vars)) @["blocked"])
  (test (:list vars) @[]))
