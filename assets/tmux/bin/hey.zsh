#!/usr/bin/env zsh
set -euo pipefail

if [[ -n ${DOTFILES_BIN:-} ]]; then
  exec "$DOTFILES_BIN/hey" "$@"
fi
exec hey "$@"
