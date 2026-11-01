{
  config,
  lib,
  ...
}: {
  options.my.services.foo.enable =
    lib.mkEnableOption "fixture local foo service";

  config = lib.mkIf config.my.services.foo.enable {
    environment.variables.NIXI_LOCAL_MODULE = "1";
  };
}
