# Declarative Doom Emacs

`modules.editors.emacs.enable` installs Doom through
[nix-doom-emacs-unstraightened](https://github.com/marienz/nix-doom-emacs-unstraightened).
Both flakes pin the integration, Doom core/modules, and Emacs package overlay.
Enable it explicitly in your own host configuration; editor selection stays
under the consumer's control.

The base package is Emacs 31.1: native Cocoa with native compilation on macOS,
and PGTK (GTK/Wayland) on Linux. It uses the pinned unstable platform recipe
with the official GNU release tarball and a fixed hash. `srcRepo = false`
selects archive build steps but does not select that archive by itself, so the
explicit source override is retained.

The recipe retains all four inherited Nixpkgs patches, including the upstream
TRAMP and Flymake security corrections. Two local patches then enforce
whole-string validation of expanded/default TRAMP usernames and select canonical
literal CA filenames without enumerating their parent directory. Host/IPv6
grammar, wildcard/handler behavior and TLS verification remain intact.

Doom selects an external GNU ELPA Flymake 1.4.7 ahead of the base library. Its
archive lacks the base editor's trusted-backend guard. The module uses
`emacsPackageOverrides` to checksum-verify, patch and deterministically repack
that archive. ELPA installs from `src` directly; adding a `patches` attribute
alone would not apply the correction. Normal byte/native compilation phases and
inherited recipe attributes are preserved.

`emacs-policy` checks source, patch order, native compilation, Tree-sitter,
Cocoa/PGTK and Doom wiring on all three supported systems, including negative
controls for missing guards and dropped recipe attributes. The opt-in probes
in `test_tools` check compiled security behavior, certificate selection, strict
local TLS, grammar loading and scoped synthetic Eglot workflows. These probes
use disposable fixtures and never load private Doom configuration.

The inherited trust policy can disable Eglot on untrusted content. Known upstream
column-zero diagnostic and disabled-backend callback behavior remains separate
from this security integration. Optional functional patches are excluded.
Normal Finder/session behavior and live consumer deployment require acceptance
on the target host; a package build alone does not activate the editor.

Override `package` to choose another backend. Source version/hash and local
patches are maintained together in `modules/shared/editors/emacs.nix`.

The core adapter adds Git, ripgrep and fd, matching the pinned Doom builder's
default tool set. It uses `assets/doom-minimal`, without workstation aliases or
a symbol font. `extraPackages` adds tools to both the user environment and Doom's
wrapper PATH; `latex = true` adds medium TeX Live independently.

Select the existing workstation preset to retain the bundled Doom configuration,
the larger build/spelling/media helper collection, Linux binutils, symbol font
and aliases:

```nix
modules.profiles.doom-workstation.enable = true;
```

The preset defaults Emacs on. Explicitly disabling Emacs suppresses its tools,
font and aliases too. Helper packages retain their low priority so other modules'
tools can take precedence. Consumer `extraPackages` follow preset helpers in the
wrapper PATH; ordinary alias definitions can override the preset's defaults.

All native Tree-sitter grammars provided by the pinned Emacs package set are
installed through `epkgs.treesit-grammars.with-all-grammars` on both platforms.
No manual grammar downloads are needed. This makes grammars available to
Emacs' built-in `treesit` API; it does not automatically enable Tree-sitter
editing modes or Doom language-module flags. The module's `extraPackages`
option still refers to external tools, not this upstream Emacs-package selector.

## Configuration and updates

The workstation preset selects `nixi/assets/doom/init.el`, `config.el`, and
`packages.el`. Edit the selected configuration or supply your own `doomDir`, then
run `hey sync`. Nix builds Doom initialization and package dependencies into the
store. No `doom-install`, `doom install`, or `doom sync` step is needed.
Restart Emacs after switching generations. Custom `package!` recipes should
include commit pins. Configuration stays in Elisp; `doomDir` can select another
versioned source directory.

The workstation `init.el` enables the macOS module only on Darwin. Its
`config.el` sets Command to Meta and preserves Option for keyboard characters
on macOS; Linux retains
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
The workstation preset supplies `e` for emacsclient, `et` for a terminal frame
and `emacs-debug` for `emacs --debug-init`. No daemon is enabled automatically.

First builds can be substantial. Unstraightened uses import-from-derivation
to determine package dependencies, so evaluation can build helper derivations
and fetch pinned sources. Evaluating a complete Doom package for another
platform requires a builder for that platform; this is not cross-compilation.
The `emacs-policy` check uses a synthetic Doom constructor to verify package,
priority, preset, bundle-registration and Tree-sitter argument wiring on all three
configuration targets with IFD disabled. It does not build Emacs or prove grammar
loading, native compilation or Finder behavior; those remain acceptance gates.
