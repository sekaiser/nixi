{
  nixi,
  runCommand,
  ...
}: let
  actual = nixi.lib.mergeChecks [
    {
      aarch64-darwin.framework = "framework-darwin";
      aarch64-linux.framework = "framework-linux";
    }
    null
    {
      aarch64-darwin.site = "site-darwin";
      x86_64-linux.site = "site-x86-linux";
    }
    {
      aarch64-darwin.host = "host-darwin";
    }
  ];

  expected = {
    aarch64-darwin = {
      framework = "framework-darwin";
      host = "host-darwin";
      site = "site-darwin";
    };
    aarch64-linux.framework = "framework-linux";
    x86_64-linux.site = "site-x86-linux";
  };

  inherit (nixi.lib) mergeAttrs' mergeChecks;
  firstDrv = runCommand "first-merge-leaf" {passthru.firstOnly = true;} ''touch "$out"'';
  lastDrv = runCommand "last-merge-leaf" {passthru.lastOnly = true;} ''touch "$out"'';
  mergedDrv = (mergeAttrs' [{package = firstDrv;} {package = lastDrv;}]).package;
  lazyChecks = mergeChecks [
    {aarch64-darwin.broken = throw "unrelated check must remain lazy";}
    {aarch64-darwin.working = "working";}
  ];
  duplicateChecks = mergeChecks [
    {aarch64-darwin.collision = throw "check values must not be inspected for collisions";}
    {aarch64-darwin.collision = lastDrv;}
  ];
in
  assert actual == expected;
  assert mergeAttrs' [] == {};
  assert mergeAttrs' [{value = 1;} {value = 2;}] == {value = 2;};
  assert mergeAttrs' [{value = [1];} {value = [2 3];}] == {value = [1 2 3];};
  assert mergeAttrs' [{value.nested = 1;} {value.other = 2;}]
  == {
    value = {
      nested = 1;
      other = 2;
    };
  };
  assert mergeAttrs' [{value = [1];} {value = null;}] == {value = null;};
  assert mergeAttrs' [{value.nested = 1;} {value = false;}] == {value = false;};
  assert mergedDrv.drvPath == lastDrv.drvPath;
  assert !(mergedDrv ? firstOnly) && mergedDrv.lastOnly;
  assert mergeChecks [null {}] == {};
  assert lazyChecks.aarch64-darwin.working == "working";
  assert builtins.attrNames lazyChecks.aarch64-darwin == ["broken" "working"];
  assert !(builtins.tryEval (builtins.attrNames duplicateChecks.aarch64-darwin)).success;
  assert !(builtins.tryEval (builtins.attrNames (mergeChecks [actual actual]).aarch64-darwin)).success;
    runCommand "merge-checks-check" {
      checked = builtins.toJSON actual;
    } ''
      touch "$out"
    ''
