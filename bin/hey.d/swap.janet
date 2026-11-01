#!/usr/bin/env janet
# List legacy swapped files for manual recovery (read-only).
#
# SYNOPSIS:
#   swap [-l|--list]
#
# DESCRIPTION:
#   The old swap/unswap operations were retired because restoring a link could
#   discard local edits. This command only reads the legacy inventory; sync
#   continues to warn about outstanding files.
#
#   Preserve the editable file before restoring its .swapped link. See
#   docs/migration.md for recovery instructions. No files are changed here.
#
# OPTIONS:
#   -l, --list
#     List all known swapped files, including dangling saved symlinks.

(use hey)
(use hey/cmd)

(defn- list []
  (let [store (path :data "swap")]
    (if (path/file? store)
      (filter |(os/lstat (string $ ".swapped"))
              (unmarshal (slurp store)))
      @[])))

(defcmd swap [_ & targets &opts list? [-l --list]]
  (unless (empty? targets)
    (abort "Swap mutations were removed. Use hey swap --list and preserve local edits before manual recovery; see docs/migration.md."))
  (echo ;(list)))
