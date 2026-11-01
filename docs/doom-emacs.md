# Declarative Doom Emacs

`modules.editors.emacs.enable` installs Doom through
[nix-doom-emacs-unstraightened](https://github.com/marienz/nix-doom-emacs-unstraightened).
Both flakes pin the integration, Doom core/modules, and Emacs package overlay.
Enable it explicitly in your own host configuration; editor selection stays
under the consumer's control.

The base package is Emacs 31.1: native Cocoa with native compilation on macOS,
and PGTK (GTK/Wayland) on Linux. It uses the pinned unstable Nixpkgs `emacs31`
or `emacs31-pgtk` recipe with the official 31.1 release tarball and a fixed hash,
instead of the recipe's prerelease source. No unrelated Nixpkgs inputs are updated.
Override `package` for another backend. The release version and source hash are
maintained together in `nixi/modules/shared/editors/emacs.nix`.
Unstraightened itself defaults to ordinary `pkgs.emacs`; the platform selection
is explicit in our module. No Homebrew Emacs, standalone app download, or
additional Emacs Plus patch set is used. External tools follow hlissner's Emacs module.
Optional `latex = true` adds medium TeX Live; `extraPackages` adds external tools.

All native Tree-sitter grammars provided by the pinned Emacs package set are
installed through `epkgs.treesit-grammars.with-all-grammars` on both platforms.
No manual grammar downloads are needed. This makes grammars available to
Emacs' built-in `treesit` API; it does not automatically enable Tree-sitter
editing modes or Doom language-module flags. The module's `extraPackages`
option still refers to external tools, not this upstream Emacs-package selector.

## Configuration and updates

Edit `nixi/assets/doom/init.el`, `config.el`, and `packages.el`, then run
`hey sync`. Nix builds Doom initialization and package dependencies into the
store. No `doom-install`, `doom install`, or `doom sync` step is needed.
Restart Emacs after switching generations. Custom `package!` recipes should
include commit pins. Configuration stays in Elisp; `doomDir` can select another
versioned source directory.

`init.el` enables the macOS module only on Darwin. `config.el` sets Command to
Meta and preserves Option for keyboard characters on macOS; Linux retains
standard modifier behavior. Language/module choices otherwise remain shared.

Update the integration and its pinned dependencies with
`nix flake update doom-emacs`, followed by `hey sync`. For standalone nixi,
run the update from the `nixi` directory too. Use Nix generation rollback for
code/configuration rollback; writable runtime state is not rolled back.

The wrapper selects the built Doom configuration and stores writable state at
`~/.local/share/nix-doom` (`doomLocalDir`). Old writable Doom installations are
not deleted or managed. Remove any manually exported DOOMDIR/DOOMLOCALDIR
overrides when migrating. Do not use `doom upgrade` for this installation.

On macOS, the complete Doom package is also registered as a system package so
nix-darwin exposes its wrapped `Emacs.app` at `/Applications/Nix Apps/Emacs.app`
after `hey sync`. Finder launches the same Nix-managed Doom configuration as
the terminal; no separate hand-maintained launcher or Homebrew app is needed.
The retired `macoslinker` script is not part of this integration; removing it
does not remove or replace the Nix-managed application bundle.
Aliases: `e` for emacsclient, `et` for a terminal frame, `emacs-debug` for
`emacs --debug-init`. No daemon is enabled automatically.

First builds can be substantial. Unstraightened uses import-from-derivation
to determine package dependencies, so evaluation can build helper derivations
and fetch pinned sources. Evaluating a complete Doom package for another
platform requires a builder for that platform; this is not cross-compilation.
