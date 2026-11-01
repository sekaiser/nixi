# Kokedera shell colors. These values intentionally use ANSI roles so ls, eza,
# zsh completion, and Alacritty stay aligned through the terminal palette.

export CLICOLOR=1
export LSCOLORS="Gxfxcxdxbxegedabagacad"

typeset -g LS_COLORS="\
no=0:\
fi=0:\
di=01;32:\
ln=36:\
pi=33:\
so=35:\
bd=33;40:\
cd=33;40:\
or=31:\
mi=31:\
ex=01;32:\
*.7z=31:\
*.bz2=31:\
*.gz=31:\
*.tar=31:\
*.tgz=31:\
*.xz=31:\
*.zip=31:\
*.zst=31:\
*.jpg=35:\
*.jpeg=35:\
*.png=35:\
*.gif=35:\
*.webp=35:\
*.mp3=33:\
*.mp4=33:\
*.m4a=33:\
*.mov=33:\
*.wav=33:\
*.pdf=31:\
*.md=36:\
*.nix=32:\
*.janet=32:\
*.rs=32:\
*.toml=33:\
*.yaml=33:\
*.yml=33:\
ma=48;2;42;61;38;38;2;200;216;184"
export LS_COLORS

zstyle ':completion:*:default' list-colors ${(s.:.)LS_COLORS}
zstyle ':completion:*:corrections' format '%B%F{green}%d (errors: %e)%f%b'
zstyle ':completion:*:messages' format '%B%F{yellow}%d%f%b'
zstyle ':completion:*:warnings' format '%B%F{red}No such %d%f%b'
zstyle ':completion:*:errors' format '%B%F{red}No such %d%f%b'
zstyle ':completion:*:descriptions' format $'%{\e[38;2;126;196;108;1m%}%d%{\e[0m%}'
zstyle ':completion:*:*:kill:*:processes' list-colors \
  '=(#b) #([0-9]#) ([0-9a-z-]#)*=32=0=0'
