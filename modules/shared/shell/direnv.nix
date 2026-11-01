{
  hey,
  ...
}: let
  inherit (hey.lib) mkBoolOpt;
in {
  options.modules.shell.direnv = {
    enable = mkBoolOpt false;
    hideEnvDiff = mkBoolOpt true;
  };
}
