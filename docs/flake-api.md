# Flake Composition API

Nixi exposes two flake composition entrypoints:

- `nixi.lib.mkHostFlake` is the public API for host and fleet flakes that
  consume `nixi` as an input.
- `lib.mkFlake` is the workspace/framework API used when the caller imports the
  local Nixi library directly and owns framework output assembly.

Both functions produce the same broad output shape. They differ in ownership,
host normalization, dependency defaults, and system selection.

## Choosing An Entrypoint

| Question | `mkFlake` | `mkHostFlake` |
| --- | --- | --- |
| Intended caller | Nixi framework or combined source workspace | External host or fleet flake |
| Call shape | `lib.mkFlake inputs definitions` | `inputs.nixi.lib.mkHostFlake { ... }` |
| Host input | Normalized descriptors, normally from `lib.mapHosts` | Inline descriptors, descriptor paths, or normalized descriptors |
| `systems` | Required | Optional; derived from hosts by default |
| Dependency source | Caller's complete framework input set | Consumer inputs layered over `nixi.inputs` |
| Framework source | `hey`, defaulting to caller `self` | `nixi`, defaulting to `inputs.nixi` |
| Stability | Workspace compatibility API | Stable consumer API |

Use `mkHostFlake` unless the flake is assembling Nixi itself or a combined
workspace that directly imports `nixi/lib`.

## `mkHostFlake`

Minimal external host flake:

```nix
{
  inputs.nixi.url = "github:example/nixi";

  outputs = inputs:
    inputs.nixi.lib.mkHostFlake {
      inherit inputs;

      hosts.laptop = {
        system = "aarch64-darwin";
        module = ./hosts/laptop.nix;
      };
    };
}
```

Signature:

```nix
nixi.lib.mkHostFlake {
  inputs;
  hosts;

  self ? inputs.self or inputs.nixi;
  nixi ? inputs.nixi or self;
  hey ? nixi;

  nixpkgs ? inputs.nixpkgs or nixi.inputs.nixpkgs;
  nixpkgs-darwin ? inputs.nixpkgs-darwin
                    or nixi.inputs.nixpkgs-darwin
                    or nixpkgs;
  nixpkgs-unstable ? inputs.nixpkgs-unstable
                      or nixi.inputs.nixpkgs-unstable
                      or nixpkgs;
  darwin ? inputs.darwin or nixi.inputs.darwin or null;
  home-manager ? inputs.home-manager
                   or nixi.inputs.home-manager
                   or null;

  apps ? {};
  checks ? {};
  devShells ? {};
  modules ? {};
  overlays ? {};
  packages ? {};
  hostModules ? [];
  nixpkgsConfig ? {};
  systems ? null;
}
```

`inputs` and `hosts` are required.

Consumer inputs override same-named framework inputs. This lets a host flake
pin a different `nixpkgs`, `home-manager`, policy flake, or other dependency
without mutating Nixi.

Explicit dependency arguments to `mkHostFlake` take precedence over consumer
inputs, which take precedence over framework defaults. The effective set is
shared by system constructors, module discovery, and `hey.inputs`/`self.inputs`.
Home Manager is imported through that same module context on both platforms.
Adapter arguments (including dependency objects) are not emitted as flake outputs.

Host packages and exported packages, checks and dev shells share one package
factory: Linux uses `nixpkgs`, Darwin uses `nixpkgs-darwin`, and both expose
`pkgs.unstable` from `nixpkgs-unstable`. The selected overlays (in attribute-name
order) and `nixpkgsConfig` apply to both stable and unstable sets.
`mkHostFlake` applies only the consumer's explicit `overlays` (empty by default).
Neither `nixi.overlays` nor the legacy `nixi.overlayDefs` catalog is inherited.
Public Nixi packages, checks and dev shells likewise use upstream pins by default.
To opt into the temporary security overrides, add this composition argument:

```nix
overlays.security = inputs.nixi.overlays.security;
```

The selected overlay then applies consistently to hosts and exported package
contexts, including `pkgs.unstable`. It may trigger large transitive rebuilds;
inspect `hey sync plan` before building. Exporting an overlay does not enable it.

Each host may be:

```nix
hosts.laptop = {
  system = "aarch64-darwin";
  module = ./hosts/laptop-module.nix;
};
```

```nix
hosts.laptop = ./hosts/laptop.nix;
```

Descriptor paths may return an attribute set or a function returning one.
`mkHostFlake` normalizes both forms and validates the host descriptor contract.

When `systems` is omitted, per-system outputs are generated for the unique
systems declared by the hosts. Passing `systems` overrides only per-system
output selection; it does not invent host configurations for undeclared
platforms.

### Disko and image hosts

Disko is an explicit Linux module import; it is not loaded for ordinary hosts:

```nix
hosts.image = {
  system = "aarch64-linux";
  module = { ... }: {
    imports = [ inputs.nixi.nixosModules.disko ];
    # Declare disko.devices and any image/profile policy here.
  };
};
```

The module uses the composed `disko` input, so consumers can override the
framework pin. It only imports Disko; it does not select a disk layout or run
partitioning. The legacy Linux descriptor `target = "qcow-efi"` remains
supported as a compatibility adapter to this import. New hosts should use an
explicit import and the default `runtime` target. Darwin cannot use this target.

### Darwin SOPS

`darwinModules.sops-darwin` is a separate opt-in provider adapter using the
consumer's `sops-nix` input. It supplies protected RAM-backed secret paths for
privileged Nixi consumers on macOS without changing `/var/run` permissions or
adding SOPS to ordinary hosts. See [secret-provider setup](secrets.md#protected-sops-sources-on-macos).

## `mkFlake`

Combined workspace example:

```nix
outputs = inputs: let
  lib = import ./nixi/lib {
    inherit (inputs.nixpkgs) lib;
    inherit (inputs) darwin home-manager;
    pkgs = import inputs.nixpkgs {};
  };
in
  lib.mkFlake inputs {
    inherit lib;

    hosts = lib.mapHosts ./hosts;
    modules.default = import ./nixi;
    checks = lib.mapModules ./nixi/checks import;
    packages = lib.mapModules ./nixi/packages import;
    systems = ["aarch64-darwin" "aarch64-linux" "x86_64-linux"];
  };
```

Signature:

```nix
lib.mkFlake inputs {
  systems;

  apps ? {};
  checks ? {};
  devShells ? {};
  hosts ? {};
  hostModules ? [];
  nixpkgsConfig ? {};
  modules ? {};
  overlays ? {};
  packages ? {};

  # Other non-reserved attributes are preserved as flake outputs.
}
```

`mkFlake` expects the complete framework input set as its first argument.
`systems` is required because this API may expose packages, checks, and shells
without declaring any hosts.

Unlike `mkHostFlake`, `mkFlake` does not normalize raw host descriptors.
Provide descriptors through `lib.mapHosts` or normalize them before calling
the function. This keeps host discovery separate from output assembly.

`mkFlake` remains supported for Nixi itself and combined workspaces. New
standalone host repositories should use `mkHostFlake`.

## Shared Definitions

Both entrypoints accept:

- `apps`: app output definitions, emitted for each selected system.
- `checks`: `callPackage` definitions emitted under `checks`.
- `devShells`: `callPackage` definitions emitted under `devShells`.
- `modules`: reusable modules exported as both `nixosModules` and
  `darwinModules`.
- `overlays`: overlays applied to host and per-system package sets.
- `packages`: recursive `callPackage` definitions emitted under `packages`.
- `hostModules`: ordinary NixOS/nix-darwin modules imported into every host;
  guard platform-specific options in shared policy.
- `nixpkgsConfig`: Nixpkgs import configuration shared by host, unstable, and
  per-system package sets (empty by default, including no unfree opt-in).

Package-like definitions receive the selected system's `pkgs` and may reference
siblings through the injected `self` package set. A sibling's derivation is not
evaluated merely to discover the output names. In particular, a failing check
does not prevent selecting a host or an unrelated package.

To combine per-system check output maps, use
`nixi.lib.mergeChecks [framework.checks consumer.checks]`. Duplicate check names
within a system are errors; rename or namespace them explicitly. The merge
inspects names only and does not force check derivations. It is separate from
the `checks` recipe argument above.

For platform filtering, supply explicit metadata around a recipe:

```nix
packages.linux-tool = {
  systems = ["aarch64-linux" "x86_64-linux"];
  package = ./packages/linux-tool.nix;
};
```

This wrapper also works for checks and dev shells. Plain recipes remain valid.
Derivation `meta.platforms` is no longer used to filter output names: inspecting
it would eagerly evaluate all the recipes. Keep normal package metadata for
Nixpkgs' own platform support checks.

## Host Module Context

A host descriptor's `module` function receives:

```nix
{
  args;
  hey;
  lib;
  modules;
}
```

- `args.host` is the normalized host name.
- `modules` contains reusable module outputs selected from flake inputs.
- `hey.inputs` contains the composed framework and consumer inputs.
- `hey.packages`, `hey.devShell`, and `hey.apps` contain host-system outputs.

The resulting NixOS or nix-darwin module graph also receives `self` and `hey`
through `specialArgs`.

Path fields are immutable evaluation-time source paths:

- `hey.dir`: selected host flake or workspace source.
- `hey.hostDir`: `${hey.dir}/hosts`.
- `hey.frameworkDir`: reusable framework source.
- `hey.assetsDir`, `hey.binDir`, `hey.libDir`, `hey.modulesDir`, and
  `hey.runtimeDir`: paths below `hey.frameworkDir`.

Mutable checkout discovery belongs to the `hey` runtime and does not affect
flake evaluation.

## Output Contract

Both entrypoints can produce:

```text
apps.<system>
checks.<system>
darwinConfigurations.<host>
darwinModules
devShells.<system>
nixosConfigurations.<host>
nixosModules
packages.<system>
```

Internal declaration attributes such as `hosts`, `modules`, and `systems` are
not leaked as raw top-level outputs. Module declarations are exposed through
the standard `nixosModules` and `darwinModules` outputs.

The fixture checks under `checks/` cover external consumers, system derivation,
overlays, packages, apps, dev shells, reusable module outputs, input layering,
and workspace composition.
