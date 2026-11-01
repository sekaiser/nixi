#!/usr/bin/env zsh

alias cr='cargo run'
alias cb='cargo build'
alias cc='cargo check'
alias ccl='cargo clippy --all-targets --all-features'
alias cf='cargo fmt'
alias ct='cargo test'
alias cnt='cargo nextest run'
alias cw='cargo watch -x check -x test'
alias ba='bacon'
alias ci='cargo insta'

alias caud='cargo audit'
alias cdeny='cargo deny check'
alias ccov='cargo llvm-cov nextest'
alias cmut='cargo mutants'
alias cudeps='cargo +nightly udeps'
alias cflame='cargo flamegraph'
