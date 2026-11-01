{lib}: let
  nonNullAttrs = lib.filterAttrs (_: value: value != null);
  # Do not include rejected values/names in errors: they may be private.
  singleLine = value: builtins.match "[^[:cntrl:]]*" value != null;
  sectionName = name:
    name
    != ""
    && singleLine name
    && builtins.match ".*[[:space:]].*" name == null
    && lib.all (char: !lib.hasInfix char name) ["[" "]" "\"" "'" "\\"];
  keyName = name: builtins.match "[a-zA-Z0-9_-]+" name != null;
  renderValue = value:
    if value == true
    then "true"
    else if value == false
    then "false"
    else toString value;
in
  prefix: name: values: extra:
    if !sectionName name
    then throw "modules.shell.awscli2: INI section names must be nonempty and contain no whitespace, control characters, brackets, quotes or backslashes."
    else if !lib.all keyName (builtins.attrNames (values // extra))
    then throw "modules.shell.awscli2: INI keys must contain only letters, digits, underscores or hyphens."
    else if !lib.all (value: singleLine (renderValue value)) (builtins.attrValues (nonNullAttrs values))
    then throw "modules.shell.awscli2: structured INI values must not contain control characters (including newlines). Use extraConfig only for intentional trusted raw INI values."
    else
      lib.concatStringsSep "\n" (
        ["[${prefix}${name}]"]
        ++ lib.mapAttrsToList
        (key: value: "${key} = ${renderValue value}")
        (nonNullAttrs (values // extra))
      )
