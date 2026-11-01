(import spork/path)
(use ./lib)

(defn- run-stdin [args input]
  (with [proc (os/spawn args :p {:in :pipe :out :pipe :err :pipe})]
    (ev/write (proc :in) input)
    (:close (proc :in))
    (let [[_out _err status]
          (ev/gather
            (ev/read (proc :out) :all)
            (ev/read (proc :err) :all)
            (os/proc-wait proc))]
      status)))

(defn- command-output [args]
  (with [proc (os/spawn args :p {:out :pipe :err :pipe})]
    (let [[out _err status]
          (ev/gather
            (ev/read (proc :out) :all)
            (ev/read (proc :err) :all)
            (os/proc-wait proc))]
      (when (= 0 status)
        (string/trim (or out ""))))))

(defn- wayland-copy-args [type once]
  @["wl-copy" ;(opts "-t" type) ;(opts (if once "-o"))])

(defn play-sound [name &named volume]
  (when (path/find "play")
    (when-let [file (path/sibling :file (path :theme "sounds" name)
                                  ".ogg" ".wav" ".mp3")]
      (os/spawn ["play" "-q" ;(opts "-v" volume) file] :pd))))

(defn notify [message &named urgency title icon sound]
  (when (path/find "notify-send")
    (os/spawn ["notify-send"
               ;(opts "-i" icon)
               ;(opts "-u" urgency)
               ;(if title
                  [title message]
                  [message])]
              :pd))
  (if sound (play-sound sound)))

(defn yank [text &named type once]
  (case (flake/info :desktop :type)
    "wayland" (run-stdin (wayland-copy-args type once) (string text "\n"))
    "x11"     (run-stdin @["xclip" "-selection" "clipboard" "-i"] (string text "\n"))))

(defn yank-file [file &named type once]
  (case (flake/info :desktop :type)
    "wayland" (os/execute @[;(wayland-copy-args type once) file] :p)
    "x11"     (os/execute @["xclip" "-selection" "clipboard" "-i" file] :p)))

(defn paste []
  (case (flake/info :desktop :type)
    "wayland" (command-output @["wl-paste"])
    "x11"     (command-output @["xclip" "-selection" "clipboard" "-o"])))
