(use hey)
(import hey/process)
(use ./support)

(defn run []
  (let [root (process/temporary-directory "hey-check-unit")
        cleanup (trap (fn [&] (path/rmtree root)) :exit)
        env @["env"
              (string "JANET_PATH=" (path :framework "runtime") ":" (or (os/getenv "JANET_PATH") ""))
              (string "DOTFILES_HOME=" (path :home))
              (string "XDG_BIN_HOME=" root "/bin")
              (string "XDG_CACHE_HOME=" root "/cache")
              (string "XDG_CONFIG_HOME=" root "/config")
              (string "XDG_DATA_HOME=" root "/data")
              (string "XDG_RUNTIME_DIR=" root "/runtime")
              (string "XDG_STATE_HOME=" root "/state")]]
    (each dir ["bin" "cache" "config" "data" "runtime" "state"]
      (path/mkdirp (path/join root dir)))
    (unless (check-command "unit tests" [;env (if-let [tree (os/getenv "JANET_TREE")]
                                              (path/join tree "bin/judge")
                                              "judge") (path :framework "test/hey")])
      (exit 1))))
