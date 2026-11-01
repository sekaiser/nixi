{
  hey,
  self,
  lib,
  options,
  config,
  ...
}: let
  inherit (lib) concatMapStringsSep isList mapAttrs mkAliasDefinitions mkIf mkOption;
  inherit (hey.lib) mapModulesRec' mkOpt;
in {
  imports = mapModulesRec' ./modules/shared import;

  options = {
    modules = {};

    # Creates a simpler, polymorphic alias for users.users.$USER.
    user = mkOpt lib.types.attrs {name = "";};

    env = mkOption {
      type = lib.types.attrsOf (lib.types.oneOf [
        lib.types.str
        lib.types.path
        (lib.types.listOf (lib.types.either lib.types.str lib.types.path))
      ]);
      apply =
        mapAttrs
        (n: v:
          if isList v
          then concatMapStringsSep ":" (x: toString x) v
          else (toString v));
      default = {};
      description = "Literal environment variables exported by the shared system module. Lists are joined with colons; shell expressions are not expanded. Use environment.extraInit for explicit shell code.";
    };
  };

  config = {
    assertions = [
      {
        assertion = config.user.name != "";
        message = "config.user.name is not set!";
      }
      {
        assertion = lib.all (name: builtins.match "[a-zA-Z_][a-zA-Z0-9_]*" name != null) (builtins.attrNames config.env);
        message = "env names must be valid shell variable identifiers.";
      }
    ];

    users.users.${config.user.name} = mkAliasDefinitions options.user;
    system.configurationRevision = mkIf (self ? rev) (lib.mkDefault self.rev);
  };
}
