{
  runCommand,
  lib,
  heyRuntimeDir ? ../runtime,
  ...
}:
runCommand "hey-janet-lib" {} ''
  mkdir -p "$out"
  ln -s ${lib.escapeShellArg "${heyRuntimeDir}/hey"} "$out/hey"
''
