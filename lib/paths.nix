{
  lib,
  ...
}: let
  inherit (builtins) foldl' hashString pathExists readFile toString;
  inherit (lib) elem;
in {
  uniqueContentPaths = paths:
    (foldl'
      (acc: path: let
        pathString = toString path;
        key =
          if pathExists pathString
          then hashString "sha256" (readFile pathString)
          else pathString;
      in
        if elem key acc.keys
        then acc
        else {
          keys = acc.keys ++ [key];
          paths = acc.paths ++ [path];
        })
      {
        keys = [];
        paths = [];
      }
      paths)
    .paths;
}
