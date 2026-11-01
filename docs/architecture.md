# Architecture Direction

This configuration should be usable as both a simple single-host dotfiles setup
and as a scalable fleet-management system for many NixOS and nix-darwin hosts.

The long-term user-facing dependency direction is:

```text
hey CLI -> host config -> reusable Nix framework (nixi)
```

`nixi` provides mechanisms. Host flakes provide final composition. Any shared
private policy is just an ordinary flake input imported by the host flake.

The clean dependency rule is:

```text
nixi exports APIs.
hosts consume nixi APIs.
hosts may also consume ordinary local files and flake inputs.
```

`nixi` must not consume sites or hosts. Hosts are the composition root.

Nix evaluation uses immutable source paths from flake inputs. It does not infer
the active checkout from `HOME`, `PWD`, `DOTFILES`, `HEYENV`, or mutable files
under the user's home directory. `hey.dir` identifies the selected host
flake's source, while `hey.frameworkDir`, `hey.assetsDir`, `hey.binDir`, and
`hey.runtimeDir` identify the reusable framework source.

Mutable workspace selection belongs to the `hey` runtime. Outside the legacy
`HEYENV` compatibility override, runtime commands prefer explicit `DOTFILES`
or `DOTFILES_HOME`, then the conventional `$HOME/.config/nix-darwin` checkout,
and finally the immutable flake source embedded in the installed `hey`
package. External workspaces can always be selected explicitly with `--flake`.

## Module/Runtime Boundary

Nix modules own declarative runtime expectations. They render generic command,
directory, and file requirements to `hey/capabilities.json`; Janet reads that
versioned manifest, validates its schema, and performs the checks.

Janet still owns behavior that depends on live process state or
application-specific parsing, such as classifying Codegraph processes and
inspecting Codex or omp configuration contents. This keeps policy and option
resolution in Nix without forcing runtime effects into evaluation.

Per-agent manifests contain only data needed for those specialized checks.
Generic health requirements must not be duplicated there. The capability
schema should remain intentionally small rather than becoming a general
runtime configuration language.

## Core Contract

The core contract should be small:

- `nixi.lib.mkHostFlake` consumes host descriptors.
- Host descriptors import normal Nix modules.
- External inputs are ordinary flakes.
- Local extensions are ordinary Nix modules.
- Everything else is standard Nix composition.

Directory discovery follows one convention everywhere:

- A directory with `default.nix` is an explicit entry point.
- Recursive discovery stops at that directory.
- A directory without `default.nix` is a grouping directory.
- Entry points import their own child modules explicitly.
- A directory with `.noload` is ignored by discovery, even if it also contains
  `default.nix`.
- Duplicate discovered names are errors, not silent overrides.

This keeps automatic discovery useful without making every helper file or
submodule globally visible by accident.

```nix
inputs.nixi.lib.mkHostFlake {
  inherit inputs;

  hosts = {
    laptop = {
      system = "aarch64-linux";
      module = ./hosts/laptop.nix;
    };
  };
}
```

## Vision

The goal is to make Nix feel like a practical, extensible system platform
rather than a collection of one-off configuration examples.

If the boundaries are right, the same model should support:

- one laptop with one host descriptor
- a small personal homelab
- many VMs grouped by fleet or cluster
- private organizational policy
- public reusable framework code
- local modules and profiles that never need to be upstreamed into `nixi`

The architecture should preserve what Nix promises:

- reproducible machine definitions
- reusable modules
- explicit dependencies
- replaceable policy layers
- target-specific evaluation and fetching
- composition without copy-paste
- fleet scale without every host inheriting every possible input

The guardrail is simplicity. The default user path must stay small:

```nix
{
  system = "aarch64-linux";

  module = {...}: {
    modules.profiles.server.enable = true;
  };
}
```

```sh
hey sync
```

Everything beyond that should be optional power-user surface.

The most important fleet property is that each host or VM should build only
what it actually needs. When the right layout is chosen, a host-specific flake
or fleet-specific host flake declares only the inputs needed by that target or
fleet. A small Linux VM should not fetch or evaluate darwin-only inputs,
desktop-only modules, unrelated private policy, or provisioning tools that it
does not import.

This is a layout property, not magic. A single global flake that declares every
possible input for every host will still have a global input graph. To maximize
target-specific fetching and evaluation, move the composition root closer to the
host or fleet being built.

## Non-Goals

`nixi` should avoid owning concerns that belong to host flakes or ordinary
consumer flakes:

- `nixi` does not define user hosts.
- `nixi` does not manage private policy.
- `nixi` does not require a site flake.
- `nixi` does not require a specific secrets backend.
- `nixi` does not need to own every profile or module.
- `nixi` does not hide normal Nix module imports behind a custom subsystem.

The design should lean on standard Nix composition wherever possible.

## Layers

### Framework (`nixi`)

The framework is the reusable Nix system engine. It provides:

- host descriptor parsing and builders
- NixOS and nix-darwin modules
- profiles
- packages and overlays
- checks
- the `hey` CLI

The framework should not need to know personal host names, private secrets
repositories, project-specific Git configuration, or organization-specific
policy. It should expose public module options and helper APIs that hosts,
local modules, and external flakes can consume.

### Shared And Local Inputs

Host flakes can consume ordinary flake inputs and local files. A flake named
`site` is only a common convention for shared private policy; it is not a
special framework concept.

Such inputs can provide:

- private modules and profiles
- secret backend conventions
- organization defaults
- private overlays
- project configuration
- fleet conventions

Separate flakes are not required for secrets, profiles, or modules. A host
flake may define its own profiles, modules, and secret wiring directly. A
shared policy flake is useful when the same private policy should be reused
across multiple hosts, host flakes, users, or fleets.

`nixi` should not know whether such inputs exist. It should only expose public
APIs that any host, local module, or external flake can use.

Security-sensitive mechanisms follow the same boundary. For example, `nixi`
provides SSH certificate modules for user CA trust, host CA trust, and host
certificate installation, while host flakes or site flakes provide actual CA
keys, signed certificates, principals, and validity policy. See
[ssh.md](ssh.md).

## Extensions Outside `nixi`

Users can define profiles and modules without extending `nixi`.

`nixi` may provide common public profiles, but local profiles can live in a
host flake, in a site flake, or in another reusable flake. The same is true for
custom modules. Hosts decide which modules and profiles to import.

Example host-local profile:

```text
$USER/.dotfiles
  flake.nix
  hosts/
    laptop.nix
  profiles/
    workstation.nix
    private-git.nix
```

```nix
# profiles/workstation.nix
{...}: {
  modules = {
    shell.zsh.enable = true;
    shell.git.enable = true;
    shell.tmux.enable = true;
  };
}
```

```nix
# hosts/laptop.nix
{
  system = "aarch64-linux";

  module = {...}: {
    imports = [
      ../profiles/workstation.nix
      ../profiles/private-git.nix
    ];
  };
}
```

The same profile can later be moved into a site flake if it becomes useful
across multiple host flakes.

Example host-local module:

```text
$USER/.dotfiles
  flake.nix
  hosts/
    laptop.nix
  modules/
    my-service.nix
```

```nix
# modules/my-service.nix
{config, lib, pkgs, ...}: {
  options.my.services.foo.enable =
    lib.mkEnableOption "my local foo service";

  config = lib.mkIf config.my.services.foo.enable {
    systemd.services.foo = {
      wantedBy = ["multi-user.target"];
      serviceConfig.ExecStart = "${pkgs.hello}/bin/hello";
    };
  };
}
```

```nix
# hosts/laptop.nix
{
  system = "aarch64-linux";

  module = {...}: {
    imports = [
      ../modules/my-service.nix
    ];

    my.services.foo.enable = true;
  };
}
```

External modules should use public `nixi` APIs when they interact with `nixi`.
They should not rely on generated files, activation script names, or private
framework paths.

## Shared Policy Inputs

There is no `nixi` site API. A shared policy flake is just a normal flake.
The smallest valid one can export nothing:

```nix
{
  outputs = inputs: {};
}
```

Most useful shared policy flakes expose ordinary flake outputs such as modules,
overlays, and checks:

```nix
{
  outputs = inputs: {
    nixosModules = {
      defaults = ./modules/nixos/defaults.nix;
      secrets = ./modules/nixos/secrets.nix;
      k8sWorker = ./modules/nixos/k8s-worker.nix;
    };

    darwinModules = {
      defaults = ./modules/darwin/defaults.nix;
      secrets = ./modules/darwin/secrets.nix;
      workstation = ./modules/darwin/workstation.nix;
    };

    overlays = {
      default = final: prev: {};
    };

    checks = {};
  };
}
```

The exact names are owned by that flake. The host flake decides which modules
to import.

External modules should configure public `nixi` options or define their own
public options.

Good:

```nix
{
  modules.services.tailscale.keyFile = config.sops.secrets."tailscale/auth_key".path;
  modules.shell.git.profileFiles.work = {
    config.sections = [
      {
        name = "user";
        settings.email = "person@example.com";
      }
    ];
  };
}
```

Avoid:

```nix
{
  # Avoid relying on internal generated files, activation script names, or
  # framework-private paths.
  system.activationScripts.someFrameworkInternalStep.text = "...";
}
```

### Secret Provider Contract

`nixi` should not mandate a specific secret backend. Hosts own final secret
selection and may wire secrets directly. A shared policy flake may provide
reusable secret backend conventions for SOPS, agenix, one-password, plain local
files for throwaway labs, or a custom runtime mechanism.

The preferred pattern is:

```nix
{
  sops.secrets."service/token" = {};

  modules.services.someService.tokenFile =
    config.sops.secrets."service/token".path;
}
```

The `nixi`-facing contract is the runtime file option, not SOPS itself.
Therefore, the same `nixi` service module can work with any secret backend that
can produce a runtime file.

There is no magic here. Host flakes work because they are normal flakes.
External modules work because they are normal Nix modules. `nixi` only provides
builders, modules, profiles, and the `hey` UX on top of standard Nix
composition.

## Host Usage

A host flake imports exactly what it needs:

```nix
{
  system = "aarch64-linux";

  module = {hey, ...}: {
    imports = [
      hey.inputs.site.nixosModules.defaults
      hey.inputs.site.nixosModules.secrets
      ./profiles/local-workstation.nix
      ./modules/my-service.nix
    ];

    modules.profiles.server.enable = true;
  };
}
```

This keeps the host descriptor honest: the host shows which `nixi`, local, and
third-party modules it consumes. `site` is only one possible input name.

## Host Flake

A host flake is the composition root for one or more machines. It declares:

- the hosts that exist
- the target system for each host
- the `nixi`, local, and external modules each host uses
- optional site modules or policy
- host-specific overrides

For simple users, the host flake can be the only flake they edit.

## Operator Workflow

The `hey` CLI should make the selected composition root explicit without
requiring users to remember raw Nix output paths.

For the local root flake, the familiar commands are enough:

```sh
hey host list
hey check flake
hey check eval
hey sync --explain
hey sync
```

For an external host flake, the same workflow accepts `--flake`:

```sh
hey host list --flake ./fleet
hey check --flake ./fleet eval analytics
hey check --flake ./fleet flake
hey check --flake ./fleet eval
hey check --flake ./fleet build analytics
hey sync --flake ./fleet#analytics --explain
hey sync --flake ./fleet#analytics
```

The safe inspection loop is:

```sh
hey host list --flake ./fleet
hey -! check --flake ./fleet eval analytics
hey -! check --flake ./fleet build analytics
hey sync --flake ./fleet#analytics --explain
```

`hey -! check ... eval HOST` and `hey -! check ... build HOST` print the
candidate Nix evaluation/build targets without evaluating or building the
selected flake. `hey sync --explain` prints the rebuild command, environment
values, and resolved build target without activating anything. Together, these
commands make it possible to verify the selected host flake and host name
before a real system switch.

`hey check --flake` uses `--no-write-lock-file` for inspection queries. It may
still warn when a lockless flake would need a lock update, but it should not
leave generated lock files behind.

For NixOS VM and image workflows, the same flake reference should be used all
the way through:

```sh
hey image list analytics --flake ./fleet
hey image build analytics --flake ./fleet
hey utm create-image --vm analytics --flake ./fleet#analytics --force
hey utm update analytics --flake ./fleet#analytics
hey utm diff analytics --flake ./fleet#analytics
hey watch eval analytics --flake ./fleet
hey watch flake --flake ./fleet
```

The important rule is that `FLAKE#HOST` names the composition root and the host
descriptor together. UTM image creation, UTM updates, image builds, checks, and
sync should all resolve to the same NixOS host output.

## Host Descriptor API

The host descriptor is the stable user-facing API. A host descriptor should be
enough to describe a machine without requiring the user to understand the
`nixi` internals.

`mkFlake` and `mkHostFlake` compose descriptors into flake outputs but serve
different callers. See [Flake Composition API](flake-api.md) for their complete
contracts and choice rule.

Example shape:

```nix
{
  system = "aarch64-linux";

  module = {...}: {
    modules.profiles.server.enable = true;
  };
}
```

Advanced hosts can still import site or `nixi` modules explicitly:

```nix
{
  system = "aarch64-linux";

  module = {hey, ...}: {
    imports = [
      hey.inputs.site.nixosModules.k8sWorker
    ];

    modules.profiles.homelab-k3s-agent.enable = true;
  };
}
```

The same host descriptor model should work for a single laptop, one VM, or a
fleet of many hosts.

`mkHostFlake` accepts descriptors in two equivalent forms:

```nix
hosts.laptop = {
  system = "aarch64-linux";
  module = ./hosts/laptop-module.nix;
};
```

```nix
hosts.laptop = ./hosts/laptop.nix;
```

The second form keeps host inventories compact. The descriptor file may return
that attribute set directly or return a function that produces it. After import,
the descriptor must contain at minimum `system` and `module`.
Use descriptor paths for larger inventories; inline descriptors are still useful
for very small root host flakes.

## Supported Layouts

The architecture should support three equivalent usage patterns.

### Workspace Flake

```text
$USER/.dotfiles
  flake.nix              # workspace entrypoint
  hosts/
    laptop.nix
    analytics.nix
  nixi/                  # reusable mechanisms, often checked out locally
    flake.nix
  site-flake/
    flake.nix            # personal/team/org policy and private providers
```

The workspace flake is a development-oriented layout. It is useful when the
framework, site policy, and host inventory are all being evolved together and
should be tested from one checkout.

The root flake is the workspace and host entrypoint. It composes the framework,
site input, and root `hosts/` inventory directly, exposes combined checks, and
makes it easy to run the same commands against local framework and site changes
before publishing them.

The workspace root should not mirror framework directories with symlinks or
other bridge files. Framework code lives under `nixi/`; host inventory lives
under `hosts/`; optional private policy lives behind an ordinary site input.
Root-level paths should be real workspace entrypoints, not compatibility
aliases.

Migration note: after removing an older root bridge layout, the currently
installed `hey` may still come from a previous system generation and may still
expect root-level framework paths such as `$DOTFILES_HOME/bin`. Run the first
activation from the framework checkout directly:

```sh
nixi/bin/hey sync
```

After that activation, the installed `hey` should be generated with the new
framework paths, so normal `hey sync` is the steady-state workflow again.

When the framework and host inventory live in the same Git checkout, direct
composition is often simpler than making the root flake lock subdirectories of
itself as inputs. The physical workspace boundary still exists, while the root
flake remains a developer entry point.

This layout is useful for framework development, private site development, and
larger operators who need to work across laptops, servers, VMs, and clusters in
one workspace.

Example pseudocode:

```nix
# $USER/.dotfiles/flake.nix
{
  inputs = {
    nixpkgs.url = "nixpkgs/nixos-26.05";
    # other framework and host inputs live here when this root flake is the
    # workspace entry point for the checkout.
  };

  outputs = inputs: let
    lib = import ./nixi/lib {
      inherit (inputs.nixpkgs) lib;
      # pass the remaining framework inputs needed by nixi/lib
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
}
```

If `nixi`, `site`, and the host inventory are separate Git checkouts, a root
workspace can still aggregate them as ordinary flake inputs. That is useful for
operators who intentionally want a separate host repository; it is not required
for the simple single-checkout layout.

```nix
# $USER/.dotfiles/fleet/flake.nix
{
  inputs = {
    nixi.url = "path:../nixi";
    site.url = "path:../site-flake";
  };

  outputs = inputs:
    inputs.nixi.lib.mkHostFlake {
      inherit inputs;

      hosts = {
        laptop = ./hosts/laptop.nix;
        analytics = ./hosts/analytics.nix;
      };
    };
}
```

### Host Flake With Site Input

```text
$USER/.dotfiles
  flake.nix              # host inventory and build entrypoint
  hosts/
    laptop.nix
    k8s/
      eks-bastion.nix
      analytics.nix
      dashboard.nix
```

The host flake references `nixi` and the site flake directly. The host
inventory is the main project, while the site flake provides optional private
policy such as SOPS defaults, work Git configuration, fleet conventions, or
organization profiles.

This layout is useful when host definitions should be versioned and deployed as
their own unit, but still share private defaults. It also works well for
clusters or fleets: one host flake can define all k8s-related VMs while another
host flake defines personal laptops.

This is likely the best fit for a mixed environment where some groups of hosts
belong together and should share a flake, while the reusable `nixi` framework
remains external.

Example pseudocode:

```nix
# $USER/.dotfiles/flake.nix
{
  inputs = {
    nixi.url = "github:example/nixi";
    site.url = "git+ssh://git@example.com/team/nix-site.git";
  };

  outputs = inputs:
    inputs.nixi.lib.mkHostFlake {
      inherit inputs;

      hosts = {
        eks-bastion = ./hosts/k8s/eks-bastion.nix;
        analytics = ./hosts/k8s/analytics.nix;
        dashboard = ./hosts/k8s/dashboard.nix;
      };
    };
}
```

```nix
# $USER/.dotfiles/hosts/k8s/analytics.nix
{
  system = "aarch64-linux";

  module = {hey, ...}: {
    imports = [
      hey.inputs.site.nixosModules.homelabSecrets
      hey.inputs.site.nixosModules.k8sWorkerDefaults
    ];

    modules.profiles.homelab-k3s-agent.enable = true;
  };
}
```

### Root Host Flake

```text
$USER/.dotfiles
  flake.nix              # host flake
  hosts/
    laptop.nix           # optional; small setups may inline this
```

The root flake is the host flake. It references `nixi` directly and may
optionally reference a site flake. This is the smallest and most approachable
layout.

This layout is useful for users who only need one machine or a few machines and
do not want to understand the `nixi` internals. They edit one flake and one
host descriptor, then use `hey sync`.

The site flake is optional here. A user can start without one and add it later
when they need private modules, shared defaults, or SOPS-backed secrets.

Example pseudocode:

```nix
# $USER/.dotfiles/flake.nix
{
  inputs = {
    nixi.url = "github:example/nixi";
    site.url = "git+ssh://git@example.com/me/nix-site.git";
  };

  outputs = inputs:
    inputs.nixi.lib.mkHostFlake {
      inherit inputs;

      hosts.laptop = {
        system = "aarch64-darwin";

        module = {hey, ...}: {
          imports = [
            hey.inputs.site.darwinModules.personalGit
          ];

          modules = {
            profiles.user = "alice";
            shell.git.enable = true;
            shell.zsh.enable = true;
            shell.tmux.enable = true;
          };
        };
      };
    };
}
```

Without a site flake, the same shape stays small:

```nix
{
  inputs.nixi.url = "github:example/nixi";

  outputs = inputs:
    inputs.nixi.lib.mkHostFlake {
      inherit inputs;

      hosts.laptop = {
        system = "aarch64-linux";
        module = {...}: {
          modules.profiles.server.enable = true;
        };
      };
    };
}
```

## Input Laziness

Host flakes should declare only the inputs needed by the hosts they build. This
keeps evaluation, fetching, and building focused on the selected target.

A small Linux host should not need to fetch or evaluate darwin-only inputs,
desktop packages, unrelated private project config, or provisioning tools that
it does not use.

This is the main reason to move the composition root closer to host flakes over
time.

`mkHostFlake` derives its per-system outputs from the systems declared by the
host descriptors unless `systems` is passed explicitly. A Linux-only host flake
therefore does not expose darwin package, app, shell, or check outputs by
default. The `root-host-flake` fixture keeps this behavior covered.

## Root Entry Point

The current root flake is the canonical workspace and host entry point.
Commands such as:

```sh
hey sync
nix eval .#darwinConfigurations.laptop.system.drvPath
```

must keep working without a nested host flake or bridge directories.

New framework APIs should be validated with fixture host flakes, and only then
adopted by real hosts.
