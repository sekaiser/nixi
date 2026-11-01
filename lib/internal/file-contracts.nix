# Internal module validation; not part of the flattened public library API.
{lib}: let
  clean = value: builtins.match "[^[:cntrl:]\\\\]+" value != null;
  components = value: lib.splitString "/" value;
  validParts = parts: lib.all (part: part != "" && part != "." && part != "..") parts;
  absolute = value: clean value && lib.hasPrefix "/" value && validParts (lib.drop 1 (components value));
  runtimeSecret = value:
    builtins.isString value
    && !builtins.hasContext value
    && absolute value
    && value != builtins.storeDir
    && !lib.hasPrefix "${builtins.storeDir}/" value;
  # Equality and file/directory overlaps are both collisions. Siblings such as
  # team and teammate are distinct; callers validate canonical paths separately.
  disjointPaths = values:
    values
    == []
    || (let
      first = builtins.head values;
      rest = builtins.tail values;
    in
      lib.all (other: first != other && !lib.hasPrefix "${first}/" other && !lib.hasPrefix "${other}/" first) rest
      && disjointPaths rest);
in {
  inherit absolute disjointPaths runtimeSecret;
  relative = value: clean value && validParts (components value);
  runtimeSecretPath =
    (lib.types.addCheck lib.types.str runtimeSecret)
    // {
      description = "canonical absolute runtime secret path (quoted string without Nix context, outside the store)";
    };
  requireRuntimeSecretPath = value:
    if value == null || runtimeSecret value
    then value
    else throw "Runtime secret paths must be canonical absolute quoted strings, never Nix paths, contextual strings or store references";
  unique = values: builtins.length values == builtins.length (lib.unique values);
  principals = values: values != [] && lib.all (value: clean value && !(lib.hasInfix "," value)) values;
}
