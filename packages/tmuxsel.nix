{
  lib,
  stdenv,
  writeShellScriptBin,
  tmux,
  coreutils,
  gawk,
  lsof,
  procps,
  ...
}:
(writeShellScriptBin "tmuxsel" ''
  # Darwin supplies pgrep in /usr/bin; Linux uses the packaged procps.
  export PATH=${lib.makeBinPath ([tmux coreutils gawk lsof] ++ lib.optionals stdenv.isLinux [procps])}:"$PATH"
  ${builtins.readFile ../bin/tmuxsel}
'')
.overrideAttrs (_: {
  meta = {
    description = "Interactive tmux session selector";
    mainProgram = "tmuxsel";
    license = lib.licenses.mit;
  };
})
