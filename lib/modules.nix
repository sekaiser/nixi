{
  lib,
  attrs,
  hostlib ? import ./hostlib.nix {inherit lib;},
}: let
  inherit (builtins) attrNames attrValues concatLists filter foldl' intersectAttrs listToAttrs map mapAttrs pathExists readDir toString;
  inherit (lib) assertMsg concatStringsSep id mapAttrsToList filterAttrs hasPrefix hasSuffix nameValuePair removeSuffix;

  visible = name: !(hasPrefix "_" name);
  # Interpolating a Nix path copies that subtree to the store. Discovery must
  # retain the enclosing source tree so relative imports still resolve there.
  childPath = dir: name: "${toString dir}/${name}";
  hasDefault = dir: pathExists (childPath dir "default.nix");
  hasNoLoad = dir: pathExists (childPath dir ".noload");
  loadableDir = dir: name:
    visible name
    && !(hasNoLoad (childPath dir name));
  canRecurseInto = dir: name:
    loadableDir dir name
    && !(hasDefault (childPath dir name));
  recursiveDirs = dir:
    mapAttrsToList (name: _: nameValuePair name (childPath dir name))
    (filterAttrs (name: kind: kind == "directory" && canRecurseInto dir name) (readDir dir));
  loadableNixFile = name:
    name
    != "default.nix"
    && name != "flake.nix"
    && hasSuffix ".nix" name;
  duplicateNames = names: let
    counts =
      foldl'
      (acc: name:
        acc
        // {
          ${name} = (acc.${name} or 0) + 1;
        })
      {}
      names;
  in
    attrNames (filterAttrs (_: count: count > 1) counts);
  moduleEntry = dir: fn: n: v: let
    path = childPath dir n;
  in
    if !(visible n) || (v == "directory" && hasNoLoad path)
    then nameValuePair "" null
    else if v == "directory" && pathExists "${path}/default.nix"
    then nameValuePair n (fn path)
    else if v == "regular" && loadableNixFile n
    then nameValuePair (removeSuffix ".nix" n) (fn path)
    else nameValuePair "" null;
  checkedEntries = dir: entries: let
    duplicates = duplicateNames (map (entry: entry.name) entries);
  in
    assert assertMsg (duplicates == [])
    "Duplicate module entry names in ${toString dir}: ${concatStringsSep ", " duplicates}"; entries;
  moduleEntries = dir: fn:
    checkedEntries dir (filter (entry: entry.name != "" && entry.value != null)
      (mapAttrsToList (moduleEntry dir fn) (readDir dir)));
  mergeHostModules = left: right: let
    duplicates = attrNames (intersectAttrs left right);
  in
    assert assertMsg (duplicates == [])
    "Duplicate host names discovered: ${concatStringsSep ", " duplicates}";
      left // right;
in rec {
  mapModules = dir: fn:
    listToAttrs (moduleEntries dir fn);

  mapModules' = dir: fn:
    attrValues (mapModules dir fn);

  # dir -> fn :: attrs (attrs (attrs ...))
  #
  # Creates a file tree where each leaf is the result of FN.
  mapModulesRec = dir: fn: let
    dirs = map (entry: nameValuePair entry.name (mapModulesRec entry.value fn)) (recursiveDirs dir);
  in
    listToAttrs (checkedEntries dir (moduleEntries dir fn ++ dirs));

  # dir -> fn :: listOf paths
  #
  # Returns a list of all files under DIR, mapped by FN.
  mapModulesRec' = dir: fn: let
    dirs = recursiveDirs dir;
    entries = moduleEntries dir id;
    paths = map (entry: entry.value) entries ++ concatLists (map (entry: mapModulesRec' entry.value id) dirs);
  in
    builtins.seq (checkedEntries dir (entries ++ dirs)) (map fn paths);

  mapHostModulesRec = dir: let
    dirs = map (entry: entry.value) (recursiveDirs dir);
  in
    foldl' mergeHostModules (mapModules dir id) (map (d: mapHostModulesRec d) dirs);

  # dir -> attrs
  #
  # Loads host descriptors from a directory tree. A directory with default.nix
  # is a host; a directory without default.nix is a grouping directory.
  mapHosts = dir:
    mapAttrs (hostName: path:
      hostlib.normalizeHostDescriptor hostName {
        inherit path;
        config = hostlib.importHostDescriptor path;
      })
    (mapHostModulesRec dir);
}
