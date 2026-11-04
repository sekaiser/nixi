(import spork/path)
(import spork/json)
(import ./subprocess)

# % and mod are both modulo functions. We don't need two, so I take over one of
# them for this common use-case:
(def fmt string/format)

(defmacro ignore-errors
  "Like protect, but returns the result of BODY or nil on errors."
  [& body]
  ~(try (upscope ,;body) ([err fib] nil)))

(defmacro peg!
  "Compile static PAT at compile-time and return it."
  [pat]
  (eval ~(peg/compile ,pat)))

(defmacro with-envvars [args & body]
  (let [xs (struct ;args)
        $old (gensym)]
    ~(let [,$old ,(struct ;(catseq [[k _] :pairs xs] [k ~(os/getenv ,k)]))]
       (defer (do ,;(catseq [k :keys xs] [~(os/setenv ,k (get ,$old ,k))]))
         ,;(catseq [[k v] :pairs xs] [~(os/setenv ,k ,v)])
         ,;body))))

(defmacro with-umask [umask & body]
  ~(let [old (os/umask ,umask)]
     (defer (os/umask old)
       ,;body)))

(def- *atomic-types*
  {:nil true
   :boolean true
   :number true
   :string true
   :buffer true
   :symbol true
   :keyword true})

(defn atom?
  "Return non-nil if VALUE is an atomic type."
  [value]
  (get *atomic-types* (type value) false))

(defn falsey? [val]
  (or (not val)
      (ignore-errors (empty? val))))

(defn tuple/type? [val type]
  (and (tuple? val)
       (or (nil? type)
           (= (tuple/type val) type))))

(defmacro case*
  "Like case, but dispatch values can be tuples to represent one-off matches."
  [value & clauses]
  (let [fallback (if (odd? (length clauses)) (last clauses))
        $var (gensym)]
    ~(let [,$var ,value]
       (cond ,;(reduce
                 (fn [init [pred body]]
                   (array/concat
                    init ~(,(if (tuple/type? pred :brackets)
                              ~(index-of ,$var ,pred)
                              ~(= ,$var ,pred))
                            ,body)))
                 @[] (partition
                      2 (if fallback (slice clauses 0 -2) clauses)))
               ,fallback))))

(defn array/remove-elt [arr elt &opt all?]
  (var idx nil)
  (while (set idx (index-of elt arr))
    (array/remove arr idx)
    (unless all? (break)))
  arr)

(defn take! [n ind]
  (let [val (take n ind)
        len (length val)]
    (unless (zero? len) (array/remove ind 0 len))
    val))

(defn take-while! [pred ind]
  (let [val (take-while pred ind)
        len (length val)]
    (unless (zero? len) (array/remove ind 0 len))
    val))

(defn take-until! [pred ind]
  (let [val (take-until pred ind)
        len (length val)]
    (unless (zero? len) (array/remove ind 0 len))
    val))

(defn drop! [n ind]
  (let [val (drop n ind)
        len (length val)]
    (unless (zero? len) (array/remove ind 0 len))
    val))

(defn drop-while! [pred ind]
  (let [val (drop-while pred ind)
        len (length val)]
    (unless (zero? len) (array/remove ind (- len) len))
    val))

(defn drop-until! [pred ind]
  (let [val (drop-until pred ind)
        len (length val)]
    (unless (zero? len) (array/remove ind (- len) len))
    val))

(defn string/chomp [str]
  (if (string/has-suffix? "\n" str)
    (slice str 0 -2)
    (string str)))

(defn string/no-suffix [suffix str]
  (if (string/has-suffix? suffix str)
    (slice str 0 (- -1 (length suffix)))
    str))

(defn string/no-prefix [prefix str]
  (if (string/has-prefix? prefix str)
    (slice str (length prefix) -1)
    str))

(def- *colors*
  {:r "\e[31m"
   :g "\e[32m"
   :y "\e[33m"
   :warn "\e[33m⚠ "
   :error "\e[31m𐄂 "
   :check "\e[32m✓ "
   :debug "\e[34m"
   :reset "\e[0m"})

(defn echo [& args]
  (var args (array ;args))
  (var format :raw)
  (var color nil)
  (var output stdout)
  (each k (take-while! keyword? args)
    (case* k
      :raw  (set format :raw)
      :json (set format :json)
      :err  (set output stderr)
      [:error :warn :debug] (do (set output stderr)
                                (set color k))
      (set color k)))
  (case (length args)
    0 nil
    1 (when-let [val (first args)]
        (with-dyns [*out* output]
          (case format
            :raw (printf (if (atom? val) "%s%V%s" "%s%m%s")
                         (or (get *colors* color) "")
                         val
                         (if color "\e[0m" ""))
            :json (print (json/encode val "  " "\n"))
            (errorf "Invalid format: %s" format))))
    (each v args
      (echo format ;(if color [color] []) v))))

(defn echof [& args]
  (var args (array ;args))
  (echo ;(take-while! keyword? args)
         (string/format (first args) ;(slice args 1))))

(defn path/no-ext
  "Remove any (or a specific) file extension from PATH."
  [path & exts]
  (if (empty? exts)
    (string/join (slice (string/split "." path) 0 -2) ".")
    (or (when-let [ext (path/ext path)]
          (when (index-of ext exts)
            (string/no-suffix ext path)))
        path)))

(defn path/sibling [type path & exts]
  (when-let [base (path/no-ext path ;exts)
             ext (find |(= (os/stat (string base $) :mode) type)
                       exts)]
    (string base ext)))

(defn path/files-in
  "Like os/dir, but returns a list of absolute paths."
  [dir]
  (map |(path/join dir $) (os/dir dir)))

(defn path/abbrev "Replace /home/$USER to ~ in PATH."
  [path]
  (peg/replace (peg! ~(* ,(os/getenv "HOME"))) "~" path))

(defn path/executable?
  "Return true if PATH resolves to an executable regular file."
  [path]
  (and (= (os/stat path :mode) :file)
       (not= 0 (band (os/stat path :int-permissions) (+ 64 8 1)))))

(defn path/exists? [path]
  (truthy? (os/stat path :mode)))

(defn path/file? [path]
  (= (os/stat path :mode) :file))

(defn path/directory? [path]
  (= (os/stat path :mode) :directory))

(defn path/mkdirp
  "Create DIR and its parents if they do not already exist."
  [dir]
  (var current "")
  (each part (path/parts dir)
    (if (empty? part)
      (set current "/")
      (do
        (set current (path/join current part))
        (case (os/stat current :mode)
          :directory nil
          nil (os/mkdir current)
          (errorf "Cannot create directory %s: path exists and is not a directory" current)))))
  dir)

(defn path/rmtree
  "Remove PATH recursively if it exists."
  [target]
  (case (os/lstat target :mode)
    nil nil
    :directory (do
                 (each child (os/dir target)
                   (path/rmtree (path/join target child)))
                 (os/rmdir target))
    (os/rm target)))

(defn path/symlink? [path]
  (and (os/stat path :mode)
       (ignore-errors (os/readlink path))))

(defn- env/nonempty [name]
  (let [value (os/getenv name)]
    (if (and value (not (empty? value))) value)))

(defn path/absolute-root [name value]
  "Validate a user-state root before any caller derives writable paths from it."
  (unless (and value (not (empty? value)) (path/abspath? value)
               (not (index-of ".." (path/parts value))))
    (errorf "%s must be an absolute directory without '..': %s" name value))
  (let [root (path/normalize value)]
    (when (= root "/")
      (errorf "%s must not be the filesystem root" name))
    root))

(defn path/user-home []
  (path/absolute-root "HOME" (env/nonempty "HOME")))

(defn- xdg-root [name home fallback]
  (path/absolute-root name (or (env/nonempty name) (path/join home fallback))))

(defn- first-dir [paths]
  (some |(if (and $ (path/directory? $)) $) paths))

(def- *heyenv*
  (delay
    (let [value (env/nonempty "HEYENV")]
      (if value
        (or (ignore-errors (json/decode value :keywords true)) {})
        {}))))

(defn- heyenv [key]
  (get (*heyenv*) key))

(defn- command-output [args]
  (ignore-errors
    (let [out (string/trim (subprocess/output args 10))]
      (unless (empty? out) out))))

(defn- default-dotfiles-path []
  (or (env/nonempty "DOTFILES")
      (env/nonempty "DOTFILES_HOME")
      # An installed launcher identifies its own consumer. A leftover legacy
      # checkout must not silently redirect it when login variables are absent.
      (env/nonempty "HEY_FLAKE_ROOT")
      (first-dir [(if-let [home (env/nonempty "HOME")]
                    (path/join home ".config/nix-darwin"))])
      (ignore-errors (os/realpath (path/join (dyn :syspath) "..")))))

(def- *xdg*
    (let [user-home (path/user-home)]
      {:bin     (xdg-root "XDG_BIN_HOME" user-home ".local/bin")
       :config  (xdg-root "XDG_CONFIG_HOME" user-home ".config")
       :data    (xdg-root "XDG_DATA_HOME" user-home ".local/share")
       :cache   (xdg-root "XDG_CACHE_HOME" user-home ".cache")
       :state   (xdg-root "XDG_STATE_HOME" user-home ".local/state")
       :runtime (xdg-root "XDG_RUNTIME_DIR" user-home ".local/runtime")
       :fake    (xdg-root "XDG_FAKE_HOME" user-home ".local/user")}))

(defn path/xdg [key & args]
  (path/join (or (get *xdg* key)
                 (errorf "Invalid XDG directory: %s" key))
             ;args))

(def- *flake-info*
  # Generated by modules/hey.nix
  (or (ignore-errors
        (json/decode (slurp (path/xdg :data "hey/info.json"))
                     :keywords true))
      {}))

(defn flake/info [& args]
  (get-in *flake-info* args))

(def- *flake-commands*
  # Generated by modules/hey.nix
  (or (ignore-errors
        (json/decode (slurp (path/xdg :data "hey/commands.json"))
                     :keywords true))
      {}))

(defn flake/commands [& args]
  (if (empty? args)
    *flake-commands*
    (get-in *flake-commands* args)))

(def- *flake*
  (delay {:path  (or (heyenv :path)
                     (default-dotfiles-path)
                     (error "Could not infer dotfiles path"))
          :user  (or (heyenv :user)
                     (env/nonempty "HEY_USER")
                     (env/nonempty "USER")
                     (flake/info :identity :user)
                     (command-output @["whoami"]))
          :host  (or (heyenv :host)
                     (env/nonempty "HEY_HOST")
                     (env/nonempty "HOST")
                     (flake/info :identity :host)
                     (flake/info :host)
                     (command-output @["hostname" "-s"]))
          :theme (or (heyenv :theme)
                     (env/nonempty "HEY_THEME")
                     (env/nonempty "THEME")
                     (flake/info :theme :active))}))

(defn flake [&opt key]
  (if key (get (*flake*) key) (*flake*)))

(defn flake/json []
  (string (json/encode (flake))))

# Capture the caller's PATH before dispatch prepends Hey's managed paths. This
# lets diagnostics distinguish the user's shell selection from Hey's own tools.
(def invocation-path (or (os/getenv "PATH") ""))

(def exec-path
  (distinct
   # Generated by modules/hey.nix. The janet script may be executed from an
   # environment where PATH isn't properly set up (like a systemd service).
   @[(or (os/getenv "DOTFILES_BIN")
         (os/realpath (path/join (dyn :syspath) "../bin")))
     (path/xdg :bin)
     ;(let [pfile (path/xdg :data "hey/path")]
        (if (path/file? pfile)
          (string/split ":" (string/trimr (slurp pfile)))
          ["/run/wrappers/bin"
           (string/format "/etc/profiles/per-user/%s/bin" (flake :user))
           "/run/current-system/sw/bin"]))
     ;(string/split ":" invocation-path)]))

(defn path/find
  "Find executable NAME in PATHS (defaults to $PATH)."
  [name &opt paths]
  (if (string/find "/" name)
    (if (path/executable? name) name)
    (some |(let [p (path/join $ name)]
             (if (path/executable? p) p))
          (or paths exec-path))))

(defn- wm []
  (let [desktop (os/getenv "XDG_CURRENT_DESKTOP")]
    (case desktop
      "Hyprland" :hypr
      "bspwm"    :bspwm
      nil        (error "XDG_CURRENT_DESKTOP not set")
      (errorf "Unrecognized desktop: %s" desktop))))

(defn- framework-path []
  # The executable's framework is independent of the selected consumer flake.
  # DOTFILES_BIN supports older wrappers; layout inference is a final fallback
  # for direct Janet use without a wrapper.
  (or (env/nonempty "HEY_FRAMEWORK_ROOT")
      (if-let [bin (env/nonempty "DOTFILES_BIN")]
        (path/dirname bin))
      (let [workspace-framework (path/join (flake :path) "nixi")]
        (if (path/directory? workspace-framework)
          workspace-framework
          (flake :path)))))

(def- *paths*
  {:home     [|(flake :path)]
   :framework [|(framework-path)]
   :bin      [:framework "bin"]
   :cache    [|(path/xdg :cache "hey")]
   :config   [:framework "assets"]
   :data     [|(path/xdg :data "hey")]
   :hosts    [|(path/join (flake :path) "hosts")]
   :host     [:hosts |(or (flake :host) (error "HOST is not set"))]
   :lib      [:framework "lib"]
   :modules  [:framework "modules"]
   :runtime-lib [:framework "runtime"]
   :runtime  [|(path/xdg :runtime "hey")]
   :state    [|(path/xdg :state "hey")]
   :themes   [:modules "shared" "themes"]
   :theme    [:themes |(or (flake :theme) (error "No active theme"))]
   :wm       [:config wm]
   :wm*      [|(path/xdg :config) wm]
   :profile  ["/nix/var/nix/profiles/system"]
   :profile* [|(path/xdg :state "nix/profiles/profile")]})

(defn path "Return a path to an area within my dotfiles."
  [area & args]
  (path/join
   ;(let [segments (if (string? area) [(path/abspath area)] (get *paths* area))]
      (catseq [p :in (or segments (errorf "Unknown area: %s" area))]
        (case (type p)
          :keyword (path p)
          :function (or (p) (errorf "Path segment function returns nil in %s" area))
          :nil []
          [p])))
   ;args))

(defmacro log [& args]
  (var args (array ;args))
  (var message (first args))
  (var level 1)
  (take! 1 args)
  (when (number? message)
    (set level message)
    (set message (first args))
    (take! 1 args))
  ~(when (>= (dyn :debug -1) ,level)
     (with-dyns [*out* stderr]
       (echof :debug (string "LOG[%s]: " ,message)
              ,(path/no-ext
                (path/join ;(slice (path/parts (dyn :current-file)) -3 -1)))
              ,;args))))

(defn opts
  "Return ARGS (a tuple) if no element is nil. An empty tuple otherwise."
  [& args]
  (if (every? args) (map string args) []))

(defn plist/index [plist key]
  (label result
    (each i (range 0 (/ (length plist) 2))
      (def i (* i 2))
      (if (= (in plist i) key)
        (return result (+ i 1))))))

(defn plist/get [plist key]
  (when-let [idx (plist/index plist key)]
    (in plist idx)))

(defn plist/put [plist key val & rest]
  (when-let [idx (plist/index plist key)]
    (put plist idx val)))
