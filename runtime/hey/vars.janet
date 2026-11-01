(import spork/path)
(use hey)

(defn- key-name [key]
  (unless (or (string? key) (keyword? key) (symbol? key))
    (error "Variable keys must be single file names"))
  (let [name (string key)]
    (when (or (empty? name) (= name ".") (= name "..")
              (string/find "/" name) (string/find "\\" name)
              (string/find "\0" name))
      (error "Variable keys must be single file names"))
    name))

(defn- write-atomic [dir file value]
  (with-umask 8r077
    (path/mkdirp dir)
    # Reserve a private sibling directory; readers see only complete values.
    (let [scratch (string/trim ($< mktemp -d (path/join dir ".nixi-vars.XXXXXXXXXX")))
          replacement (path/join scratch "value")]
      (defer (path/rmtree scratch)
        (spit replacement value)
        (os/rename replacement file)))))

(defn new [dir &opt raw?]
  (let [dir (path/abspath dir)]
    {:dir (fn [self & segments] (path/join dir ;segments))
     :file (fn [self key]
             (path/join dir (key-name key)))
     :list (fn [self]
             (if (path/directory? dir)
               (map keyword (filter |(= :file (os/lstat (path/join dir $) :mode)) (os/dir dir)))
               []))
     :get (fn [self key &opt dflt]
            (let [file (:file self key)]
              (case (os/lstat file :mode)
                :file ((if raw? identity unmarshal) (slurp file))
                nil dflt
                (error "Variable is not a regular file"))))
     :set (fn [self key val]
            (let [file (:file self key)]
              (cond
                (dryrun?) (do (echof "DRYRUN: %s variable %s" (if (nil? val) "remove" "set") file)
                             (if (nil? val) key val))
                (= val nil) (when (os/lstat file)
                              (os/rm file)
                              key)
                (do (write-atomic dir file ((if raw? identity marshal) val))
                    val))))
     :clear (fn [self]
              (each key (:list self)
                (:set self key nil)))
     :cache (fn [self key valfn &opt reset?]
              (or (unless reset?
                    (:get self key))
                  (:set self key (valfn))))}))

(def global (new (path :data "vars.d")))
(def temp   (new (path :runtime "vars.d")))

(defn get [key &opt global?]
  (:get (if global? global temp) key))

(defn set [key val &opt global?]
  (:set (if global? global temp) key val))

(defn list [&opt global?]
  (:list (if global? global temp)))

(defmacro cached [vars key & body]
  ~(:cache ,vars ,key (fn [] ,;body)))
