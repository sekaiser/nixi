# Library Layout

`lib` contains evaluation-time Nix support code.

Runtime support for the `hey` CLI and shell integration lives in `runtime/`.
Keep this boundary intact: the Nix library is part of flake evaluation, while
Janet and zsh files are loaded at command or shell runtime.

## Nix Helpers

The top-level `*.nix` files and namespaced helper directories provide the local
framework used by hosts and modules:

- `default.nix` wires the helper modules together and exposes both namespaced
  and flattened helper functions.
- `modules.nix` discovers module and host files. A directory containing
  `default.nix` is treated as an explicit entry point; recursive discovery
  stops there, and that entry point is responsible for importing its own child
  modules. Files and directories whose names start with `_` are excluded,
  including directories with `default.nix`. A directory containing `.noload`
  is also skipped. These rules apply to flat, recursive and host discovery.
  Duplicate discovered
  names are rejected instead of silently overwritten, including file/group
  collisions in recursive module trees. Discovery preserves the enclosing
  source tree so grouped files can use ordinary relative imports outside the
  scanned directory.
- `hostlib.nix` owns the host descriptor contract. Host descriptor files may
  return either an attribute set directly or a function that returns one.
- `nix.nix` exposes the public flake framework entrypoints used by `flake.nix`.
  `mkFlake` is the compatibility root used by this repository; `mkHostFlake`
  is the reusable composition API for external host flakes. See
  [Flake Composition API](../docs/flake-api.md) for their contracts and choice
  rule.
- `flake/default.nix` contains the implementation helpers for host
  configurations, per-system outputs, and final flake output assembly.
- `attrs.nix`, `options.nix`, `pkgs.nix`, and `debug.nix` hold smaller helper
  groups used throughout the configuration.

`mergeAttrs'` recursively merges plain attribute sets and concatenates lists in
input order. Scalar or mixed-type conflicts use the rightmost value. Derivations
are atomic leaves, never recursively combined. To combine flake check outputs,
use `mergeChecks`: it merges system/check-name maps and rejects duplicate check
names within a system without evaluating the checks themselves.

These helpers are evaluation-time code. Avoid reading mutable machine state
from new helpers unless the caller explicitly opts into impurity.
Prefer native Nixpkgs packaging helpers to new wrapper aliases. Unused
`mkWrapper`, `mkLauncherEntry`, `toPrettyJSON` and `compileSCSS` exports were removed;
see [migration notes](../docs/migration.md) for replacements. Generated files
should normally remain derivation paths, avoiding builds during evaluation.

## Layout Conventions

- `lib/*.nix` and `lib/flake` are the Nix framework API and implementation.
- `runtime/hey` is first-party Janet runtime code for `hey`.
- `runtime/zsh` is first-party shell helper code.
- `vendor/janet` contains historical vendored Janet source trees used as
  compatibility/vendor data.

Do not move public Nix helper files casually. `lib/default.nix` exposes both
namespaced and flattened helpers, so file names are part of the practical
framework API. Prefer adding new implementation helpers under a namespace only
when it reduces coupling or keeps a public entrypoint small.
