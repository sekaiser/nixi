#!/usr/bin/env zsh
set -u

pane_id="${1:-}"
pane_id="${pane_id#%}"

if [[ -n ${HEY_TMUX_STATUS_INPUT:-} ]]; then
  pane_status="$HEY_TMUX_STATUS_INPUT"
else
  [[ -n $pane_id ]] || exit 0
  command -v tmux >/dev/null 2>&1 || exit 0

  pane_status="$(tmux show-options -gqv "@hey_pane_status_${pane_id}" 2>/dev/null || true)"
  [[ -n $pane_status ]] || exit 0

  renderer="${0:A:h}/hey-tmux-status"
  if [[ -x $renderer ]]; then
    exec "$renderer" right "$pane_status"
  elif command -v hey-tmux-status >/dev/null 2>&1; then
    exec hey-tmux-status right "$pane_status"
  fi
fi

typeset -A fields
for field in ${(ps:\t:)pane_status}; do
  key="${field%%=*}"
  value="${field#*=}"
  [[ -n $key && $key != "$value" ]] || continue
  fields[$key]="$value"
done

tmux_escape() {
  print -r -- "${1//\#/##}"
}

parts=()
[[ ${fields[direnv]:-} == 1 ]] && parts+=('#[range=user|direnv]▼#[norange]')
[[ -n ${fields[nix]:-} ]] && parts+=("#[range=user|nix]nix $(tmux_escape "${fields[nix]}")#[norange]")

git_parts=()
[[ -n ${fields[branch]:-} ]] && git_parts+=("#[fg=colour5]$(tmux_escape "${fields[branch]}")#[fg=colour8]")
[[ -n ${fields[user]:-} ]] && git_parts+=("#[fg=colour6]@$(tmux_escape "${fields[user]}")#[fg=colour8]")
[[ -n ${fields[files]:-} ]] && git_parts+=("#[fg=colour3]~${fields[files]}#[fg=colour8]")
[[ -n ${fields[added]:-} ]] && git_parts+=("#[fg=colour2]+${fields[added]}#[fg=colour8]")
[[ -n ${fields[deleted]:-} ]] && git_parts+=("#[fg=colour1]-${fields[deleted]}#[fg=colour8]")
[[ ${#git_parts} -gt 0 ]] && parts+=("#[range=user|git]${(j: :)git_parts}#[norange]")

print -r -- "${(j: :)parts}"
