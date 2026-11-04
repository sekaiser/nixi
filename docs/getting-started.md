# Getting started

Nixi is a reusable flake dependency. Keep your host repository private unless
you deliberately choose to publish it. You need Nix with `nix-command` and
`flakes` enabled, Git, and basic familiarity with NixOS or nix-darwin. Nixi is
not an OS installer. Use an existing NixOS/nix-darwin installation for activation.

## Try the synthetic example without switching systems

The complete two-platform consumer lives in [examples/minimal](../examples/minimal).
From the Nixi source root:

```sh
nix eval path:./examples/minimal#darwinConfigurations.laptop.config.networking.hostName \
  --override-input nixi "path:$PWD" --no-write-lock-file
nix eval path:./examples/minimal#nixosConfigurations.server.config.networking.hostName \
  --override-input nixi "path:$PWD" --no-write-lock-file
```

These commands override the example's placeholder URL with this checkout.
An input pointing outside a standalone path flake cannot use a relative parent
path; the explicit absolute override avoids that boundary. No lock file is
written. Do not publish locks containing private local paths.
The Linux example intentionally lacks your
machine's disk and boot configuration. Do not activate either example unchanged.

## Create your private consumer

Copy the example's `flake.nix`, `laptop.nix` and/or `server.nix` into a separate
private repository. Set `inputs.nixi.url` to the public Nixi repository once
available, or to an explicit local checkout while testing. Adjust the host names,
architectures, usernames, home paths and selected modules. Add your Linux
hardware configuration through an ordinary import in the returned system module.
Set both `system.stateVersion` and `home.stateVersion` in each host's returned
system module. Keep their existing values when migrating established machines;
these compatibility settings are not the current package release number.

```nix
{
  inputs.nixi.url = "github:YOUR-ORG/nixi"; # replace after publication
  outputs = inputs:
    inputs.nixi.lib.mkHostFlake {
      inherit inputs;
      hosts.laptop = {
        system = "aarch64-darwin";
        module = ./laptop.nix;
      };
    };
}
```

Track the intended files in your PRIVATE repository before using Git-backed
flake evaluation. Nix excludes untracked files from that source. Commit your
consumer's lock file privately. Build before switching:

```sh
nix build .#darwinConfigurations.laptop.system --no-link
# Or, on the corresponding Linux system:
nix build .#nixosConfigurations.server.config.system.build.toplevel --no-link
```

Review the resulting changes before running your existing `darwin-rebuild` or
`nixos-rebuild` switch command. With `hey.enable = true`, the installed `hey`
command provides the same workflow with explicit selection:

```sh
hey sync --explain --flake /absolute/path/to/private-hosts#laptop
hey sync --flake /absolute/path/to/private-hosts#laptop
```

The second command activates changes. It is not a preview.

## Know the defaults

The core integrates Home Manager and declares the shared module options. It does
not select extra binary caches, trusted users, a Nix version, unfree packages,
or the workstation tool collection. Those choices belong to the consumer.
Set `hey.enable = true` for the CLI, or opt into
`modules.profiles.workstation.enable = true` for the convenience tool collection
and a default-enabled CLI. Explicit `hey.enable = false` still takes precedence.
Themes, services and editor modules add opinionated settings only when selected.

Bare `modules.shell.zsh` and `modules.shell.tmux` provide tool/configuration
wiring, not a bundled desktop workflow. For the existing Nixi preferences,
opt into `modules.profiles.zsh-workstation.enable` and
`modules.profiles.tmux-workstation.enable`. The custom desktop-directory layout
is separately opt-in through `modules.profiles.home-workstation.enable`.
Atuin UI/key preferences, Rust/Go development tool collections and Neovim aliases
likewise live in the optional `atuin-workstation`, `rust-workstation`,
`go-workstation` and `vim-workstation` profiles. See the migration notes for their
scope. Explicitly disabling a base tool also suppresses its preset's effects.

`modules.shell.atuin.package` accepts an Atuin derivation, defaulting to
`pkgs.unstable.atuin`. Use it to select a different package or build features.

`modules.dev.rust.packageSet` selects `"stable"` or `"unstable"` Nixpkgs for
Rust and Cargo, plus the workstation profile's rustfmt, Clippy, rust-analyzer
and cargo-llvm-cov. The default is `"unstable"`. Select `"stable"` when you need
the stable branch's tested toolchain; other Rust utilities retain their sources.

Keep personal Doom preferences in your private host configuration. Set
`modules.editors.emacs.extraConfig` to Emacs Lisp appended after the selected
`doomDir`'s `config.el`; `init.el` and `packages.el` remain unchanged. For example:

```nix
modules.editors.emacs.extraConfig = ''
  (after! org
    (setq org-roam-directory (expand-file-name "~/notes")))
'';
```

This text enters the Nix store. Use string paths, never secret values or a Nix
path importing your notes directory. Do not publish personal system closures.

Use `hostModules = [ ./policy.nix ];` in `mkHostFlake` to share ordinary system
modules across your inventory. If needed, set `nixpkgsConfig.allowUnfree = true`
there to configure both host and per-system package sets. Native Home Manager
options remain available under `home-manager.users.<name>`; Nixi's `home.*`
aliases are conveniences, not a replacement API. Read the
[migration notes](migration.md) before upgrading an existing consumer.

Service access policy belongs to the consumer. For example, enabling
`modules.services.tang.enable` also requires explicitly setting the native
`services.tang.ipAddressAllow` option to your permitted network prefixes.
Nixi supplies no workstation-specific address or default network allowlist.

## Project workflows

Projects can retain their own flakes, `justfile`, Makefile or process definitions.
Use `hey project --help` and [CLI documentation](hey.md). To work on Nixi itself:

```sh
nix develop
hey check unit
hey check eval
hey check flake
```

`hey check cli` exercises integration commands with synthetic host/secret fixtures.
It also uses platform shell tools and inherited runtime state; do not assume
`hey check all` is a hermetic or fully cross-platform test suite.
Nix checks can evaluate other-platform modules; building their system closures
requires a corresponding native/remote builder. See [composition API](flake-api.md)
for ordinary shared-policy inputs, overrides and explicit module imports.

## Private data stays private by ownership, not magic

Keep credentials as runtime secret files, never string literals. Nix evaluation,
store outputs, generated manifests, logs and binary-cache uploads can reveal
host policy even when secrets are encrypted. Do not upload personal host closures
to public caches. Only publish separately reviewed synthetic examples; no tool
here automatically promotes a private host to a public example.
