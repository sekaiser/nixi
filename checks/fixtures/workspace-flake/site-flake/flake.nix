{
  description = "Workspace site policy fixture";

  outputs = inputs: {
    nixosModules.workspaceDefaults = {...}: {
      environment.variables.NIXI_WORKSPACE_SITE = "1";
    };

    checks.aarch64-linux.site = "site-check";
  };
}
