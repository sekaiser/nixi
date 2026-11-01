{
  pkgs,
  runCommand,
  writeTextDir,
  ...
}: let
  compose = import ../lib/internal/compose-doom-dir.nix {inherit pkgs;};
  base = runCommand "doom-config-fixture" {} ''
    mkdir -p "$out"
    printf '%s\n' '(setq example-setting "base")' > "$out/config.el"
    printf '%s\n' '(doom! :lang emacs-lisp)' > "$out/init.el"
    printf '%s\n' ';; package fixture' > "$out/packages.el"
  '';
  configured = compose {
    doomDir = base;
    extraConfig = ''(setq example-setting "consumer $value `literal`")'';
  };
  missing = compose {
    doomDir = writeTextDir "init.el" ";; minimal fixture";
    extraConfig = ";; extra-only fixture";
  };
in
  assert compose {
    doomDir = base;
    extraConfig = "";
  }
  == base;
    runCommand "doom-extra-config-check" {} ''
      cmp ${base}/init.el ${configured}/init.el
      cmp ${base}/packages.el ${configured}/packages.el
      test "$(grep -c 'setq example-setting' ${configured}/config.el)" = 2
      grep -F 'consumer $value `literal`' ${configured}/config.el
      test "$(grep -n 'base' ${configured}/config.el | cut -d: -f1)" -lt "$(grep -n 'consumer' ${configured}/config.el | cut -d: -f1)"
      grep -F 'extra-only fixture' ${missing}/config.el
      touch "$out"
    ''
