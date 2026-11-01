#!/usr/bin/env zsh

alias g='() {
    [[ $# = 0 ]] && git status --short . || git $*;
}'

alias ga='git add'
alias gaa='git add --all'
alias gap='git add --patch'
# Show local and remote branchs with latest commit
alias gb='git branch -av'
alias gop='git open'
alias gbd='git branch --delete'
alias gbd!='git branch --delete --force'
alias gbl='git blame'
alias gc='git commit -v'
alias gca='git commit -v --amend'
alias gcn='git commit -v --amend --no-edit'
alias gcall='git commit -v --all'
alias gcaall='git commit -v --all --amend'
alias gcan='git commit -v --amend --no-edit'
alias gcm='git commit -m'
alias gcam='git commit --all -m'
alias gca='git commit --amend'
alias gcf='git commit --fixup'
alias gcl='git clone'
alias gclv='git -c core.sshCommand="ssh -v" clone'
alias gbo='git checkout --branch'
alias gco='git checkout'
alias gcof='git checkout --'
alias gd='git diff'
alias gdt='git difftool --tool=difftastic --no-prompt'
alias gf='git fetch'
alias gi='git init'
alias gl='git log --graph --pretty="format:%C(yellow)%h%Creset %C(red)%G?%Creset%C(green)%d%Creset %s %Cblue(%cr) %C(bold blue)<%aN>%Creset"'
alias gli='gitlint --config ~/.config/gitlint/default.ini --commits HEAD'
alias gll='git log --pretty="format:%C(yellow)%h%Creset %C(red)%G?%Creset%C(green)%d%Creset %s %Cblue(%cr) %C(bold blue)<%aN>%Creset"'

# fzf
if (( $+commands[fzf] )); then
  __git_log () {
    # format str implies:
    #  --abbrev-commit
    #  --decorate
    git log \
      --color=always \
      --graph \
      --all \
      --date=short \
      --format="%C(bold blue)%h%C(reset) %C(green)%ad%C(reset) | %C(white)%s %C(red)[%an] %C(bold yellow)%d"
  }

  _fzf_complete_git() {
    ARGS="$@"

    # these are commands I commonly call on commit hashes.
    # cp->cherry-pick, co->checkout

    if [[ $ARGS == 'git cp'* || \
          $ARGS == 'git cherry-pick'* || \
          $ARGS == 'git co'* || \
          $ARGS == 'git checkout'* || \
          $ARGS == 'git reset'* || \
          $ARGS == 'git show'* || \
          $ARGS == 'git log'* ]]; then
      _fzf_complete "--reverse --multi" "$@" < <(__git_log)
    else
      eval "zle ${fzf_default_completion:-expand-or-complete}"
    fi
  }

  _fzf_complete_git_post() {
    sed -e 's/^[^a-z0-9]*//' | awk '{print $1}'
  }
fi
