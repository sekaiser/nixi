{
  description = "Workspace nixi layout fixture";

  inputs = {
    nixi.url = "path:../../..";
    site.url = "path:./site-flake";
    hosts.url = "path:./host-flake";
  };

  outputs = inputs: {
    checks = inputs.nixi.lib.mergeChecks [
      inputs.nixi.checks
      inputs.site.checks
      inputs.hosts.checks
    ];

    apps = inputs.nixi.apps;
  };
}
