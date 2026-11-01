# Module Layout

`modules` is split by configuration boundary:

- `shared` contains options and Home Manager modules that should work on both
  macOS and NixOS.
- `platform/darwin` contains nix-darwin modules for macOS hosts.
- `platform/linux` contains NixOS modules for Linux hosts and image flows.

Use the platform directories for platform-specific options. Keep `shared`
free of nix-darwin-only or NixOS-only option paths unless they are guarded by
the importing platform. CPU-specific policy should be an explicit host-local
or profile import until it is common enough to deserve a public module.

## Categories

The current categories have these roles:

- `profiles` compose host policy from lower-level modules. They are the right
  place for reusable host shapes such as `modules.profiles.vm-image`.
- `services` wrap system services behind this repo's option namespace.
- `shell`, `desktop`, `editors`, `dev`, and `themes` configure user-facing
  tools and Home Manager state.

Prefer adding a small lower-level module first, then composing it from a
profile, over copying the same host-level configuration between hosts.

Static file payloads live in `assets` and are exposed to modules as
`hey.assetsDir`. Use that for plain files that are copied or linked into the
target system. Keep conditional logic in modules instead of embedding it in
asset files.

## Managed Files

Modules that write generated or repo-owned files through `home.file`,
`home.configFile`, or `home.dataFile` must retain Home Manager's default collision
checks. Do not set `force = true` in framework modules: adopting a module must not
silently replace an existing user file. The `home-file-ownership` check enforces
this boundary. Both explicit attribute sets and shorthand declarations are fine.

Consumers can opt into `home-manager.backupFileExtension` or explicitly replace
individual files through native Home Manager options after reviewing ownership.
Home Manager's native XDG paths are authoritative; Nixi's path aliases and
environment variables follow them. Legacy `home.configDir` / `cacheDir` /
`dataDir` / `stateDir` definitions still work and preserve override priorities.
Use `config.home.dir` for derived account-home paths rather than the raw
`config.user.home` alias, so native account-home overrides propagate to consumers.
Custom activation that writes or removes files belongs after `writeBoundary`
and must use Home Manager's dry-run-aware `run` helper. Do not remove files before
collision validation to make that validation pass.

Home Manager uses the host package set by default, including consumer overlays
and licensing policy. Consumers can set `home-manager.useGlobalPkgs = false`
and configure a separate Home Manager package set explicitly.

Prefer native options to mirroring upstream schemas. The legacy
`modules.desktop.homebrew` names are aliases for nix-darwin's `homebrew` options;
Nixi does not enable it, upgrades or cleanup implicitly. The Git module delegates
serialization to Nixpkgs and merges with native
`home-manager.users.<user>.programs.git` settings. Legacy ordered sections render
first, native settings follow, and native includes remain last.
Git does not require Zsh; aliases are optional integration when Zsh is enabled.

`modules.editors.default = null` leaves editor selection alone. Set a command
explicitly to supply a per-user `EDITOR` default; native Home Manager session
variables can override it. Selecting an editor does not install the command.

## Host Policy

Hosts should mostly select profiles and provide host-specific values. A host
file is expected to answer questions like:

- Which user, role, platform, and hardware profile is this?
- Which reusable services are enabled?
- Which secrets or host-specific addresses are required?

Large reusable behavior should move into `modules`, not remain embedded in a
single host.

On Linux, the primary-user profile leaves supplementary groups and the login
shell at native defaults and retains shell validation. Explicitly select the
`administrator` profile for wheel membership or the `workstation` profile for
Zsh and development tools. Docker membership belongs to the Docker service
module, not generic user creation.

Use literal `env` values for global exports, and native Home Manager
`home.sessionVariables` / `home.sessionPath` for user-specific values and paths.
Intentional shell expressions belong in shell initialization, not `env` strings.
The GnuPG module delegates homedir and agent ownership to Home Manager, with
Nix-built platform-specific pinentry; it does not require Homebrew.

OMP uses Nixpkgs' YAML serializer with independently defaulted theme fields;
explicit model roles override optional Codex defaults. RTK initialization passes
the selected Codex directory directly instead of depending on ambient shell state.

The generic Caddy and Tailscale modules do not assume one another. Select
`modules.profiles.gitea-tailscale.enable` for Gitea's loopback backend, public
HTTPS listener and Tailscale certificate permissions. This profile does not
disable certificate automation for other Caddy virtual hosts. Tailscale's
authentication lifecycle belongs to the native NixOS module; Nixi's optional
runtime auth-key path is passed through systemd credentials, never shell source.
See [migration notes](../docs/migration.md) for service-name and deployment changes.

## Dependencies

Make module dependencies visible at the option boundary:

- Use `mkDefault` when a module can safely enable another module as a
  convenience default.
- Use `assertions` when a module cannot work correctly unless another option is
  enabled or configured.
- Use `mkIf` only for conditional behavior, not as the only documentation of an
  implicit dependency.

For required Zsh integration, enable Zsh with `mkDefault` or assert that
`modules.shell.zsh.enable` is true. Optional integration, such as Git aliases,
should only append rc files when Zsh is enabled, without coupling the underlying
tool to that shell.

## VM Image Profile

`platform/linux/profiles/vm-image.nix` is the model for the current VM flow. It
collects the defaults needed by image-backed UTM VMs:

- image size and root filesystem defaults
- SSH CA trust and password-auth policy
- activation sudo rules for `hey utm update`
- generation cleanup policy
- SSD-friendly defaults such as `noatime` and `fstrim`

When adding VM behavior that should apply to all image-backed VMs, prefer a new
option under `modules.profiles.vm-image` rather than repeating the setting in
each VM host.

## Homelab Profiles

Homelab hosts use a small profile stack:

- `homelab-base` sets the shared user, editor, shell, SSH, theme, and XDG
  defaults.
- `homelab-node` enables the common homelab base profile.
- `homelab-secrets` is the SOPS-specific homelab provider profile. Hosts choose
  whether to use it and which secret names it exposes.
- `homelab-k3s-agent` composes the common worker-node defaults: homelab node,
  shared `k3s/agent_token` and Tailscale secrets, k3s agent enablement, and
  Tailscale routing flags.
- `homelab-k3s-server` composes the common server-node defaults: homelab node,
  shared `k3s/agent_token` and Tailscale secrets, Tailscale routing flags, and
  k3s server enablement with the `k3s-cilium` recipe and Flux bootstrap.

The generic K3s server/agent modules do not select Tailscale or a CNI. The
`k3s-cilium` recipe uses pinned build-time chart/manifests with native K3s
reconciliation. No service module disables the firewall globally. Homelab
profiles explicitly trust their overlay interfaces; other consumers must define
the network access their services require. See [migration notes](../docs/migration.md)
before applying these changes to an existing cluster.

K3s cluster joins are intentionally based on a pre-shared SOPS-managed agent
token rather than reading `/var/lib/rancher/k3s/server/node-token` from a
running master. That makes VM activation order boring: the server and agents
can all be deployed from their host configs, and agents retry until Tailscale
and the API server are reachable. Host files still own role-specific policy,
such as the server DNS name exposed through `serverHost` or `k8sServiceHost`.
Use `serverAddr` only when an agent needs a non-standard scheme, host, or port.
When several hosts join the same cluster, prefer a site-level cluster endpoint
such as `site.k3s.homelab.serverHost` and consume that from each host file.
That keeps cluster identity in one place while preserving host-level overrides
for migrations or separate control planes.

Keep credentials and host-specific addresses in host files or SOPS-managed
secret files. Do not move literal k3s/Tailscale credentials into reusable
profiles just to reduce line count; that increases the blast radius of a
profile mistake. Prefer service `tokenFile`/`keyFile` options for future secret
migrations.

Reusable service modules should depend on runtime file options such as
`tokenFile` or `keyFile`, not on SOPS directly. Hosts and provider profiles own
the decision of where those files come from.
