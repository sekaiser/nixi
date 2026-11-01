# Alternatives I considered:
# - spork/argparse: interface is too verbose and clumsy; doesn't allow short
#   options without an accompanying long option.
# - ianthehenry/cmd: much better, but doesn't parse options beyond the escape
#   argument (sigh). Also a little more verbose than I'd like.

(import spork/path)
(use ./lib)
(import hey)

(def- *commands* @{})
(def- *argtypes* '[&opts &args &])

(defn- make-arg [arg]
  (let [spec (if (tuple? arg) arg [arg :string nil])]
    {:name (in spec 0)
     :default |(get spec 2)}))

(defn- make-opt [name spec]
  (let [spec (if (tuple? spec) spec [spec])
        {true opts false args} (group-by |(and (not (struct? $)) (string/has-prefix? "-" $)) spec)
        {true metas false args} (group-by |(struct? $) (if (nil? args) [] args))
        meta @{}]
    (if (not (nil? metas))
      (loop [m :in metas
             :when (struct? m)
             [key val] :pairs m] (put meta key val)))
    {:name name
     :options (map string opts)
     :arguments (if args (map make-arg (filter |(not= $ '*) args)))
     :meta meta}))

# Validate recognized options before invoking a command body. Unknown options
# remain forwardable for commands with an & binding; -- ends our parsing.
(defn- option-value [opt value]
  (if (= :number (get-in opt [:meta :type]))
    (or (scan-number value)
        (hey/abort "%s expects a number, got: %s" (first (opt :options)) value))
    value))

(defn- parse-args [args optbinds optmap forward?]
  (let [argv @[;args]
        rest @[]
        values @{}]
    (while (not (empty? argv))
      (def arg (first (take! 1 argv)))
      (cond
        (= arg "--")
        (do (array/push rest ;argv) (break))

        # Signed integer operands are not clustered short options.
        (peg/match '(sequence "-" (some (range "09")) -1) arg)
        (array/push rest arg)

        (and (string/has-prefix? "-" arg)
             (> (length arg) 2)
             (not (string/has-prefix? "--" arg)))
        (array/insert argv 0 ;(map |(string "-" (string/from-bytes $)) (slice arg 1)))

        (string/has-prefix? "-" arg)
        (if-let [idx (get optmap arg)]
          (let [opt (optbinds idx)
                count (length (or (opt :arguments) []))]
            (when (or (< (length argv) count)
                      (some |(or (= $ "--") (get optmap $)) (slice argv 0 count)))
              (hey/abort "Option %s requires %d value(s)" arg count))
            (def raw (take! count argv))
            (def value (case count
                         0 arg
                         1 (option-value opt (first raw))
                         [;(map |(option-value opt $) raw)]))
            (put values (opt :name)
                 (if (get-in opt [:meta :multiple])
                   [;(get values (opt :name) []) value]
                   value)))
          (if forward?
            (array/push rest arg)
            (hey/abort "Unrecognized option: %s" arg)))

        (array/push rest arg)))
    (each opt optbinds
      (when (nil? (get values (opt :name)))
        (put values (opt :name) (get-in opt [:meta :default]))))
    [rest values]))

(defmacro cmdfn [spec & body]
  (let [argspec @[;spec]
        optbinds @[]
        optmap @{}
        argbinds @[]
        restbinds @[]]
    (var arg-type
         (or (if-let [b (get argspec 1)]
               (if (or (and (symbol? b)
                            (string/has-prefix? "-" b))
                       (tuple/type? b :brackets))
                 '&opts))
             '&args))
    (while (not (empty? argspec))
      (def arg (first (take! 1 argspec)))
      (if (index-of arg *argtypes*)
        (set arg-type arg)
        (case arg-type
          '&args (array/push argbinds (make-arg arg))
          '&opts (let [opt (make-opt arg (first (take! 1 argspec)))
                       idx (length optbinds)]
                   (array/push optbinds opt)
                   (each o (get opt :options) (put optmap o idx)))
          '& (if (> (length restbinds) 2)
               (errorf "Too many & binds for %q" arg)
               (array/push restbinds arg)))))
    (with-syms [$rest $all $argmap]
      ~(fn [& args]
         (let [,$all args
               [,$rest ,$argmap] (,parse-args ,$all (quote ,optbinds) ,optmap ,(> (length restbinds) 0))]
           (let [[,;(map |($ :name) argbinds) & ,(get restbinds 0 '_)] ,$rest
                 ,;(if-not (index-of (get restbinds 1) ['_ nil]) [(get restbinds 1) $all] [])]
             ,;(map (fn [opt] ~(def ,(opt :name) (get ,$argmap ',(opt :name)))) optbinds)
             ,;body))))))

(defn cmd [name]
  (or (get *commands* name)
      (errorf "Unrecognized command: %s" name)))

(defn command-names []
  (sort (map string (keys *commands*))))

(defn- defcmd* [name cmd file]
  (put *commands* name {:cmd cmd :file file}))

(defmacro defcmd-1 [type name argspec & body] 
  ~(upscope
    (,(case type :public 'def :private 'def- (errorf "Unknown type: %s"))
      ,name (cmdfn [,;argspec] ,;body))
    ,(unless (= name 'main)
       ~(,defcmd* ',name ,name ,(path/abspath (dyn :current-file ""))))))

(defmacro defcmd- [name argspec & body]
  ~(defcmd-1 :private ,name [,;argspec] ,;body))

(defmacro defcmd [name argspec & body]
  ~(defcmd-1 :public ,name [,;argspec] ,;body))

(defmacro defmain [argspec & body]
  ~(defcmd-1 :public main [,;argspec] ,;body))
