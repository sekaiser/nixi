# OMP settings and ownership

`modules.agents.omp.manageConfig` synchronises declared defaults into a private,
user-owned, writable YAML file during Home Manager activation. Nix owns the
defaults, not the mutable file or OMP's credentials, sessions, databases or caches.

The mutable file defaults to `~/.omp/agent/config.yml`. Declared keys are refreshed
on activation. Other OMP/user settings are preserved. Removing a declaration
removes its former value only if the user has not changed it in the meantime.
Managed-key metadata contains only the non-secret defaults and stays in a private
runtime sidecar. Never put credentials in Nix options.
YAML formatting and comments may be normalised when defaults are synchronised.

OMP may edit settings between activations. Close OMP before activating changes;
the activation lock serialises Nixi activations, not OMP's independent file lock.
Set `manageConfig = false` to leave the configuration entirely user-managed.

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
