#!/usr/bin/env janet
# Operate on Nix system and user profiles.
#
# SYNOPSIS:
#   profile [-u|--user]
#   profile ls [-u|--user]
#   profile current [-u|--user]
#   profile previous [-u|--user]
#   profile rollback [GEN] [-u|--user]
#   profile rm GEN [-u|--user]
#   profile prune --keep-generations N [-u|--user]
#   profile diff [FROM] [TO] [-u|--user]
#
# SUBCOMMANDS:
#   current   Print the active generation.
#   previous  Print the generation before the active generation.
#   rollback  Switch to GEN, or previous generation when GEN is omitted.
#   ls        List profile generations.
#   rm        Remove one or more profile generations.
#   prune     Keep N entries including the active generation; no store GC.
#   diff      Compare store references between profile generations.
#
# OPTIONS:
#   -u, --user
#     Operate on the user profile instead of the system profile.
#   --keep-generations N
#     Required for prune. Keep the active entry plus the newest N-1 others.
#
# EXAMPLES:
#   hey profile rm 1042
#     Remove profile generation 1042.
#   hey profile rm -1
#     Remove the last generation (before the current one).

(use hey)
(use hey/cmd)
(import hey/process)
(import hey/system)
(import hey/generation-policy)

(defn- generation-number [profile file]
  (let [base (path/basename file)
        prefix (string (path/basename profile) "-")
        suffix "-link"]
    (when (and (string/has-prefix? prefix base)
               (string/has-suffix? suffix base))
      (let [number (string/slice base (length prefix) (- (length base) (length suffix)))]
        (when (peg/match '(* :d+ -1) number)
          (let [value (scan-number number)]
            (when (and (int? value) (> value 0)) value)))))))

(defn- current-generation [profile]
  (when-let [target (os/readlink profile)]
    (generation-number profile target)))

(defn- generations [profile]
  (let [current (current-generation profile)]
    (->> (path/files-in (path/dirname profile))
         (keep |(when-let [generation (generation-number profile $)]
                  {:generation generation
                   :current (= generation current)}))
         (sort-by |(get $ :generation)))))

(defn- generation-at [profile idx]
  (let [gens (generations profile)]
    (cond (= idx 0) (find |(get $ :current) gens)
          (< idx 0) (let [current (find-index |(get $ :current) gens)]
                      (when (and current (>= (+ current idx) 0))
                        (get gens (+ current idx))))
          (find |(= idx (get $ :generation)) gens))))

(defn- previous-generation [profile]
  (let [gens (generations profile)
        current (current-generation profile)
        idx (find-index |(= current (get $ :generation)) gens)]
    (when (and idx (> idx 0))
      (get gens (- idx 1)))))

(defn- generation-file [profile gen &opt exists?]
  (let [path (string/format "%s-%d-link"
                            profile
                            (get gen :generation))]
    (when (or (not exists?) (path/exists? path))
      path)))

(defn- remove-generations [profile args user?]
  (os/with-lock (path :runtime "profile-rm.lock")
    # Resolve every operand against one snapshot before issuing any deletion.
    (let [selected (os/readlink profile)
          gens (generations profile)
          current (find-index |(get $ :current) gens)
          plan (map (fn [arg]
                      (unless (peg/match '(sequence (? "-") (some (range "09")) -1) arg)
                        (abort "Invalid generation: %s" arg))
                      (let [idx (scan-number arg)
                            gen (if (<= idx 0)
                                  (when (and current (>= (+ current idx) 0))
                                    (get gens (+ current idx)))
                                  (find |(= idx (get $ :generation)) gens))]
                        (unless gen (abort "No profile generation: %s" arg))
                        (when (get gen :current)
                          (abort "Refusing to remove the current generation"))
                        (string (get gen :generation)))) args)]
      (unless (= selected (os/readlink profile))
        (abort "Active profile changed during removal planning; retry"))
      (system/delete-generations profile (distinct plan) user?))))

(defn- print-generation [gen]
  (if gen
    (echo :json gen)
    (abort "Could not resolve profile generation")))

(defn- prune-generations [profile keep user?]
  (generation-policy/validate-keep keep)
  (os/with-lock (path :runtime "profile-rm.lock")
    (let [gens (generations profile)
          current (current-generation profile)
          plan (generation-policy/plan (map |(get $ :generation) gens) current keep)]
      (echof "Keep generations: %s" (string/join (map string (plan :keep)) ", "))
      (echof "Delete generations: %s" (if (empty? (plan :delete)) "none" (string/join (map string (plan :delete)) ", ")))
      (unless user? (system/verify-current profile))
      (unless (= current (current-generation profile))
        (abort "Active profile changed during retention planning; retry"))
      (system/delete-generations profile (map string (plan :delete)) user?))))

(defn- switch-generation [profile gen user?]
  (let [generation (get gen :generation)]
    (if user?
      (process/run! @["nix-env" "--switch-generation" (string generation) "--profile" profile])
      (system/rollback-under-lock profile generation))))

(def- command-output process/output)

(defn- nonempty-sorted-lines [text]
  (sort
    (filter |(not (empty? $))
            (map string/trim (string/split "\n" (or text ""))))))

(defn- store-references [profile gen]
  (nonempty-sorted-lines
    (command-output @["nix-store" "-q" "--references" (generation-file profile gen)])))

(defn- line-set-difference [left right]
  (let [right-set (table)]
    (each line right
      (put right-set line true))
    (filter |(not (get right-set $)) left)))

(defn- diff [profile &opt from to]
  (let [from (generation-at profile (if from (scan-number from) 0))
        to   (generation-at profile (if to   (scan-number to)   0))]
    (when (or (nil? from) (nil? to))
      (abort "Could not resolve profile generation for diff"))
    (if (dryrun?)
      (do
        (echof "DRYRUN: nix-store -q --references %s"
               (generation-file profile from))
        (echof "DRYRUN: nix-store -q --references %s"
               (generation-file profile to)))
      (let [a (store-references profile from)
            b (store-references profile to)]
        (echo :r ;(map |(string "-" $) (line-set-difference a b)))
        (echo :g ;(map |(string "+" $) (line-set-difference b a)))))))


(defcmd profile [_ cmd & args &opts user? [-u --user]
                 keep [--keep-generations keep {:type :number}]]
  (when (and keep (not= cmd "prune"))
    (abort "--keep-generations is only supported by hey profile prune"))
  (let [profile (path (if user? :profile* :profile))]
    (case* cmd
      "current" (if (empty? args)
                  (print-generation (generation-at profile 0))
                  (abort "Usage: hey profile current"))
      "previous" (if (empty? args)
                   (print-generation (previous-generation profile))
                   (abort "Usage: hey profile previous"))
      "rollback" (if (<= (length args) 1)
                   (os/with-lock (path :runtime "profile-rm.lock")
                    (let [gen (if (empty? args)
                               (previous-generation profile)
                               (generation-at profile (scan-number (first args))))]
                     (unless gen
                       (abort "Could not resolve rollback generation"))
                     (switch-generation profile gen user?)))
                   (abort "Usage: hey profile rollback [GEN]"))
      "ls" (if (empty? args)
             (echo :json (generations profile))
             (abort "Usage: hey profile ls|rm|diff"))
      "rm" (if (empty? args)
             (abort "Usage: hey profile rm GEN")
             (remove-generations profile args user?))
      "prune" (if (and keep (empty? args))
                (prune-generations profile keep user?)
                (abort "Usage: hey profile prune --keep-generations N [-u|--user]"))
      "diff" (if (<= (length args) 2)
               (diff profile ;args)
               (abort "Usage: hey profile diff [FROM] [TO]"))
      nil (echo profile)
      (abort "Usage: hey profile ls|current|previous|rollback|rm|prune|diff"))))
