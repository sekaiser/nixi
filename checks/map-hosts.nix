{
  nixi,
  runCommand,
  ...
}: let
  hosts = nixi.lib.mapHosts ./fixtures/map-hosts;
  relativeHosts = nixi.lib.mapHosts ./fixtures/discovery-relative/hosts;
  duplicateHosts = builtins.tryEval (
    builtins.deepSeq (nixi.lib.mapHosts ./fixtures/map-hosts-duplicate) true
  );

  actual = {
    hostNames = builtins.attrNames hosts;
    duplicateRejected = !duplicateHosts.success;
    analyticsSystem = hosts.analytics.config.system;
    analyticsTarget = hosts.analytics.config.target;
    laptopSystem = hosts.laptop.config.system;
    laptopTarget = hosts.laptop.config.target;
    serverSystem = hosts.server.config.system;
    serverTarget = hosts.server.config.target;
    relativeImport = (relativeHosts.server.config.module {}).config.environment.variables.NIXI_RELATIVE_IMPORT;
  };

  expected = {
    hostNames = ["analytics" "laptop" "server"];
    duplicateRejected = true;
    analyticsSystem = "aarch64-linux";
    analyticsTarget = "runtime";
    laptopSystem = "aarch64-darwin";
    laptopTarget = "runtime";
    serverSystem = "x86_64-linux";
    serverTarget = "runtime";
    relativeImport = "relative-import-preserved";
  };
in
  assert actual == expected;
    runCommand "map-hosts-check" {
      checked = builtins.toJSON actual;
    } ''
      touch "$out"
    ''
