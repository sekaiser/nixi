{lib, ...}:
let
  inherit (builtins) traceSeqN;
in rec {
  inspect = fn: val:
    traceSeqN 10 (fn val) val;
}
