# OMP settings and ownership

`modules.agents.omp.enable` exposes diagnostics and an optional package. Settings
remain user-managed by default: no activation hook or defaults YAML is emitted,
and enabling Codex alongside OMP does not select a provider or model. Command,
state-directory and config-file diagnostics still default on; disable the
corresponding `check*` options if those expectations do not fit your installation.

To retain the former managed workstation settings, opt into:

```nix
modules.profiles.omp-workstation.enable = true;
```

The preset defaults OMP on and opts into writable-settings synchronisation. It
retains Unicode symbols, setup version 1 and Titanium/light themes. If Codex is
already enabled, it also selects the former Codex search provider and slow-model
default. It does not enable Codex or install OMP unless a package is supplied.
These are compatibility choices, not current provider/model recommendations.
Ordinary OMP option values override preset defaults. `manageConfig = false`
suppresses synchronisation; `enable = false` suppresses the OMP integration.

For a smaller declaration without the preset:

```nix
modules.agents.omp = {
  enable = true;
  manageConfig = true;
  theme.dark = "consumer-theme";
  modelRoles.slow = "example/model";
};
```

Only declared fields are synchronised. Theme fields, `symbolPreset`,
`setupVersion` and `webSearchProvider` default to `null`, which omits them;
`manageConfig = true` alone selects no preferences. The optional legacy
`configureCodexModels` convenience requires an explicit `codexModel` when Codex
is enabled. An explicit `modelRoles.slow` overrides that role. The preset supplies
both convenience values; set `configureCodexModels = false` to suppress its role.

With management explicitly selected, Home Manager activation synchronises
declared defaults into a private, user-owned, writable YAML file. Nix owns the
defaults, not the mutable file or OMP's credentials, sessions, databases or caches.

The mutable file defaults to `~/.omp/agent/config.yml`. Declared keys are refreshed
on activation. Other OMP/user settings are preserved. Removing a declaration
removes its former value only if the user has not changed it in the meantime.
Managed-key metadata contains only the non-secret defaults and stays in a private
runtime sidecar. Never put credentials in Nix options.
YAML formatting and comments may be normalised when defaults are synchronised.

OMP may edit settings between activations. Close OMP before activating changes;
the activation lock serialises Nixi activations, not OMP's independent file lock.
Turning management off leaves the existing config and private sidecars in place.
It does not retire previously applied values, move state or revoke credentials.

Older Nixi configurations linked the mutable file into the Nix store. OMP resolves
that symlink when saving, then replaces its target with a mode-0600 file. Running
OMP as root can therefore damage a store output and make it unreadable to the
normal user. The corrected integration never exposes a mutable store-backed
config to OMP. A readable legacy link is migrated with a private backup; an
unreadable one fails without discarding its settings and needs a one-time repair.
Other symlinks, insecure config files, malformed YAML and root-run activation are
rejected. Configuration values and parser error excerpts are never logged.

Do not run OMP with sudo. If it has been run that way, inspect ownership of its
state and any Bun cache it used. Repair only affected user-state entries, without
following symlinks, traversing other filesystems, or changing store permissions.
An unreadable legacy store config may contain private values: copy it to a
mode-0600 user-owned runtime backup/config rather than make the store file public.
Do not delete sessions or credentials merely to fix permissions.

The Homebrew executable can remain root-managed/read-only; only user runtime
state needs to be writable. No package or dependency override is required.
