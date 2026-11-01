#!/usr/bin/env zsh
# Swap the current pane with an adjacent one.
#
# SYNOPSIS:
#   swap-pane [up|down|left|right|master]
#
# DESCRIPTION:
#   Swaps the active tmux pane with the adjacent pane in the requested
#   direction, or with the first pane when using `master`.

local target
case $1 in
  up) target="U" ;;
  down) target="D" ;;
  left) target="L" ;;
  right) target="R" ;;
  master) target="master" ;;
  *) exit 1 ;;
esac

local src_pane=$(tmux display-message -p "#P")
if [[ "$target" == master ]]; then
  local dst_pane=$(tmux list-panes -F "#P" | head -n 1)
else
  tmux select-pane -${target} 2>/dev/null || exit 0
  local dst_pane=$(tmux display-message -p "#P")
  tmux select-pane -t${src_pane}
fi

[[ -z "$dst_pane" || "$dst_pane" == "$src_pane" ]] && exit 0

tmux swap-pane -s"$src_pane" -t"$dst_pane"
tmux select-pane -t"$src_pane"
