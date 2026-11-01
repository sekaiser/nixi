# Called with --file and --argstr, so consumer references remain data, not Nix code.
{
  flakeRef,
  attrPath,
}: {
  result = builtins.toJSON (builtins.attrNames (builtins.foldl'
    (set: name: set.${name} or {})
    (builtins.getFlake flakeRef)
    (builtins.fromJSON attrPath)));
}
