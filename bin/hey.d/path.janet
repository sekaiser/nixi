#!/usr/bin/env janet
# Prints a path to a subarea of my dotfiles.
#
# SYNOPSIS:
#   path [-e|-d|-f] [-a] [AREA] [SEGMENTS...]
#
# OPTIONS:
#   -e
#     Return nothing if resulting path doesn't exist.
#   -d, -f
#     Return nothing if resulting path isn't a directory or file (respectively).
#   -a
#     Abbreviate $HOME/ to ~/ in resulting path.
#
# VALID AREAS:
#   home           Active workspace root
#   framework      {home}/nixi, or {home} for standalone nixi
#   bin            {framework}/bin
#   cache          $XDG_CACHE_HOME/hey
#   config         {framework}/assets
#   data           $XDG_DATA_HOME/hey
#   hosts          {home}/hosts
#   host           {hosts}/$HOST/
#   lib            {framework}/lib
#   runtime-lib    {framework}/runtime
#   modules        {framework}/modules
#   runtime        $XDG_RUNTIME_DIR/hey
#   state          $XDG_STATE_HOME/hey
#   themes         {modules}/shared/themes
#   theme          {themes}/{THEME}
#   wm             {framework}/assets/{WM}/
#   wm*            $XDG_CONFIG_HOME/{WM}/
#   xdg DIR        $XDG_{DIR}_HOME

(use hey)
(use hey/cmd)

(defn- path-1 [&opt area & args]
  (try (cond (not= area "xdg")
             (path (keyword (or area :home)) ;args)
             (not (get args 0))
             (error "Usage: hey path xdg DIR [SEGMENTS...]")
             (path/xdg (keyword (string/ascii-lower (in args 0)))
                       ;(slice args 1)))
       ([err] (abort "%s" err))))

(defcmd path [_ area & args
              &opts
              exists? [-e -f -d]
              abbrev? -a]
  (let [path (path-1 area ;args)]
    (cond (case exists?
            "-e" (not (path/exists? path))
            "-f" (not (path/file? path))
            "-d" (not (path/directory? path)))
          (exit 1)

          abbrev?
          (echo (path/abbrev path))

          (echo path))))
