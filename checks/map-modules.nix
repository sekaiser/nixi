{
  nixi,
  runCommand,
  ...
}: let
  mapped = nixi.lib.mapModulesRec ./fixtures/map-modules (path: toString path);
  mappedList = map toString (nixi.lib.mapModulesRec' ./fixtures/map-modules (path: path));
  duplicateModules = builtins.tryEval (
    builtins.deepSeq (nixi.lib.mapModules ./fixtures/map-modules-duplicate (path: path)) true
  );
  duplicateRecursiveModules = builtins.tryEval (
    builtins.deepSeq (nixi.lib.mapModulesRec ./fixtures/map-modules-duplicate (path: path)) true
  );
  groupCollision = builtins.tryEval (
    builtins.deepSeq (nixi.lib.mapModulesRec ./fixtures/map-modules-group-collision import) true
  );
  groupListCollision = builtins.tryEval (
    builtins.deepSeq (nixi.lib.mapModulesRec' ./fixtures/map-modules-group-collision import) true
  );
  relative = nixi.lib.mapModulesRec ./fixtures/discovery-relative/modules import;
  hasSuffixIn = suffix: values:
    builtins.any (value: nixi.lib.hasSuffix suffix value) values;
  defaultStop = toString ./fixtures/map-modules/default-stop;

  actual = {
    flatNames = builtins.attrNames (nixi.lib.mapModules ./fixtures/map-modules (path: path));
    rootNames = builtins.attrNames mapped;
    groupNames = builtins.attrNames mapped.group;
    duplicateRejected = !duplicateModules.success;
    duplicateRecursiveRejected = !duplicateRecursiveModules.success;
    groupCollisionRejected = !groupCollision.success;
    groupListCollisionRejected = !groupListCollision.success;
    relativeImports = [relative.flat relative.group.nested];
    relativeListImports = nixi.lib.mapModulesRec' ./fixtures/discovery-relative/modules import;
    hasIgnoredTree = builtins.hasAttr "ignored" mapped;
    hasIgnoredDefault = builtins.hasAttr "ignored-default" mapped;
    defaultStopPath = mapped."default-stop";
    listHasDefaultStop = hasSuffixIn "/default-stop" mappedList;
    listHasDefaultStopNested = hasSuffixIn "/default-stop/nested.nix" mappedList;
    listHasGroupedLeaf = hasSuffixIn "/group/leaf.nix" mappedList;
    listHasRootLeaf = hasSuffixIn "/root.nix" mappedList;
    listHasHiddenEntry = builtins.any (value: nixi.lib.hasInfix "/_hidden" value) mappedList;
  };

  expected = {
    flatNames = ["default-stop" "root"];
    rootNames = ["default-stop" "group" "root"];
    groupNames = ["leaf"];
    duplicateRejected = true;
    duplicateRecursiveRejected = true;
    groupCollisionRejected = true;
    groupListCollisionRejected = true;
    relativeImports = ["relative-import-preserved" "relative-import-preserved"];
    relativeListImports = ["relative-import-preserved" "relative-import-preserved"];
    hasIgnoredTree = false;
    hasIgnoredDefault = false;
    defaultStopPath = defaultStop;
    listHasDefaultStop = true;
    listHasDefaultStopNested = false;
    listHasGroupedLeaf = true;
    listHasRootLeaf = true;
    listHasHiddenEntry = false;
  };
in
  assert actual == expected;
    runCommand "map-modules-check" {
      checked = builtins.toJSON actual;
    } ''
      touch "$out"
    ''
