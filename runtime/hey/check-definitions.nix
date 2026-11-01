{
  directory,
  system,
}: let
  entries = builtins.readDir directory;
  files = builtins.filter (name: entries.${name} == "regular" && builtins.match ".*\\.nix" name != null) (builtins.attrNames entries);
  selected = builtins.filter (name: let
    definition = import (builtins.toPath "${directory}/${name}");
  in
    !(builtins.isAttrs definition && definition ? systems && definition ? package) || builtins.elem system definition.systems)
  files;
in {
  result = builtins.toJSON (map (name: builtins.substring 0 (builtins.stringLength name - 4) name) selected);
}
