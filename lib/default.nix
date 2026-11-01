{
  lib,
  pkgs,
  darwin,
  home-manager,
  ...
}: let
  inherit (builtins) attrValues functionArgs intersectAttrs;
  inherit (lib) foldl;

  # mapModules gets special treatment because it's needed early!
  inherit (attrs) attrsToList mergeAttrs';
  inherit (modules) mapModules;
  attrs = import ./attrs.nix {inherit lib;};
  modules = import ./modules.nix {inherit lib attrs;};

  # Load lib/*.nix using a small callPackage-style environment. A lib file that
  # depends on another local lib should use a default import to avoid depending
  # on lexicographic load order.
  loadLib = a: b:
    a
    // {
      ${b.name} = b.value (intersectAttrs (functionArgs b.value) a);
    };

  libModules = mapModules ./. import;
  libs =
    foldl loadLib
    {
      inherit lib pkgs darwin home-manager;
      self = libs;
    }
    (attrsToList libModules);
in
  # The flattened tree is appended to make the namespaced endpoints optional,
  # and because namespaces are useful for inherit'ed let-bindings. In other
  # words: lib.attrsToList == lib.attrs.attrsToList.
  libs // (mergeAttrs' (attrValues libs))
