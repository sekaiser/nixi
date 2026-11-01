#!/usr/bin/env zsh
set -euo pipefail

range="${1:-}"
pane_id="${2:-}"

case "$range" in git|nix|direnv) ;; *) exit 1 ;; esac
[[ $pane_id == %<-> ]] || exit 1

# Resolve paths as data here, never interpolate them into a run-shell binding.
pane_path="$(tmux display-message -p -t "$pane_id" '#{pane_current_path}')"
[[ -n $pane_path ]] || exit 1
pane_status="$(tmux show-options -gqv "@hey_pane_status_${pane_id#%}" 2>/dev/null || true)"

status_field() {
  local wanted="$1"
  local field key value

  for field in ${(ps:\t:)pane_status}; do
    key="${field%%=*}"
    value="${field#*=}"
    [[ $key == "$wanted" && $key != "$value" ]] || continue
    print -r -- "$value"
    return 0
  done
}

case "$range" in
  git)
    tmux display-popup -E -d "$pane_path" -w 90% -h 75% \
      'git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0; git status --short --branch; printf "\n"; git diff --stat --color=always HEAD -- 2>/dev/null || git diff --stat --color=always --'
    ;;
  direnv)
    tmux display-popup -E -d "$pane_path" -w 80% -h 60% \
      'printf "path: %s\n\n" "$PWD"; if command -v direnv >/dev/null 2>&1; then direnv status; else echo "direnv not found"; fi; if [ -f .envrc ]; then printf "\n.envrc\n"; sed -n "1,120p" .envrc; fi'
    ;;
  nix)
    nix_state="$(status_field nix)"
    tmux display-popup -E -d "$pane_path" -w 80% -h 60% \
      -e "HEY_TMUX_NIX_STATE=${nix_state:-unknown}" \
      'printf "path: %s\nnix: %s\n\n" "$PWD" "$HEY_TMUX_NIX_STATE"; if [ -f flake.nix ]; then printf "flake: ./flake.nix\n"; if command -v nix >/dev/null 2>&1; then nix flake metadata --no-write-lock-file . 2>/dev/null | sed -n "1,40p"; fi; else echo "flake: none in current directory"; fi'
    ;;
esac
