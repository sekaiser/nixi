# UTM VM Flow

This repo supports two UTM workflows:

- `hey utm create-image` creates a VM from a preconfigured NixOS image.
- `hey utm update` updates an existing running VM in place.
- `hey utm rollback` rolls an existing VM back to its previous NixOS system
  generation.
- `hey utm diff` compares the local NixOS target with the running VM.
- `hey utm generations` shows the VM's system profile generations.
- `hey utm cleanup-generations` removes older VM system generations.

The image flow is the preferred path for new VMs. It moves system setup into
Nix build time, then uses UTM only to register and start the VM.

## IP discovery

Post-activation password-policy checks use the remote OpenSSH configuration
parser, including connection-specific `Match` and `Include` rules. Verification
requires readable configuration and `UseDNS no`; otherwise it fails with an
explanation instead of reporting an unverified policy as safe. It does not grant
additional sudo permissions. See [security.md](security.md) for scope and limits.

`hey utm ip VM` queries UTM and the local ARP cache without sending a subnet
ping sweep. If passive discovery fails, `hey utm ip VM --scan` explicitly allows
a local IPv4 /24 sweep, with at most eight supervised pings in flight. Use it
only on networks where you are authorized to scan. Invalid interface addresses
are not scanned. This is not an IPv6 or arbitrary-subnet scanner.

All discovery commands and pings share one monotonic 30-second deadline;
`--wait SECONDS` can shorten it. Bounded supervisor cleanup may add a short
delay after the deadline. `hey -! utm ip VM --scan` only previews the operation.
Internal callers, including SSH/EKS routing, never enable scanning implicitly.

## Create A VM

Build the `utm` image from this flake, create a UTM VM named `utm`, and start
it:

```sh
hey utm create-image --vm utm --flake .#utm --cpu 2 --ram 8192 --phases start
```

The same command can target a host from another flake:

```sh
hey utm create-image --vm utm --flake ~/Code/site-flake#utm --cpu 2 --ram 8192 --phases start
```

Replace an existing VM from a freshly built image:

```sh
hey utm create-image --vm utm --flake .#utm --cpu 2 --ram 8192 --phases start --force
```

For non-interactive replacement, add `--yes`:

```sh
hey utm create-image --vm utm --flake .#utm --cpu 2 --ram 8192 --phases start --force --yes
```

Replacement builds, converts and validates the new image before prompting to
stop/delete the old VM. Build or conversion failures leave the old VM untouched.
Each attempt uses a private, unique staging directory under UTM's `HeyImages`
directory; previous image files are never overwritten. VM names cannot contain
`/` or be `.` or `..`.

Deletion and registration waits each time out after 30 seconds. A failed UTM
query is an error, not proof that the VM disappeared. If VM creation fails after
the image is ready, Hey prints and retains the staged image path for recovery.
Successful creation removes only that attempt's staging files. Replacement is
still destructive once deletion begins: keep backups of any guest data you need;
a staged base image is not a backup of the old guest disk.

For `.#utm`, the image is built from:

```sh
.#nixosConfigurations.utm.config.system.build.images.qemu-efi
```

Image hosts should enable the shared VM image profile:

```nix
modules.profiles.vm-image = {
  enable = true;
  hostName = "utm";
  stateVersion = "26.05";
  diskSize = 51200;
  activationUser = "alice";
  autoCleanGenerations = true;
  keepGenerations = 3;
  ssdOptimizations = true;
  trustedUserCAKeys = [
    "ssh-ed25519 ..."
  ];
};
```

The profile provides the qemu guest agent, DHCP defaults, the NixOS
state version, filesystem defaults for the generated image, trusted SSH user CA
wiring, and the narrow passwordless sudo rule used by `hey utm update`. SSH
password authentication is disabled by default for image VMs; login is expected
to use an SSH user certificate trusted by the VM.

By default, image VMs keep the last three system generations. Set
`modules.profiles.vm-image.keepGenerations` per host to change that, or set
`modules.profiles.vm-image.autoCleanGenerations = false` to disable automatic
cleanup during `hey utm update`.

Automatic cleanup requires an enabled VM-image profile that explicitly allows
it in the remote `hey/info.json`. Missing or disabled profiles never authorize
deletion; malformed or unsupported metadata fails closed. Version 1 metadata
and valid legacy unversioned metadata are supported. `--keep-generations N`
overrides the count, not the auto-cleanup opt-out. The installed policy is checked
again after activation, so a newly deployed opt-out takes effect immediately.

UTM SSH commands default to Hey's configured user (`HEY_USER`), not the VM name.
Use `--user USER` for a different remote account. `--wait` bounds the entire SSH
readiness loop, including stalled probes; read-only SSH probes also have a
30-second timeout. Interactive SSH and arbitrary remote commands are not limited
by that probe timeout.

Image VMs also enable SSD-friendly defaults:

- periodic fstrim through `services.fstrim`
- `noatime` on the root filesystem

This avoids continuous discard on every delete while still allowing the guest to
tell the sparse virtual disk which blocks are unused. Set
`modules.profiles.vm-image.ssdOptimizations = false` to opt out for a specific
host.

The temporary raw image copy lives under UTM's container documents directory
while the VM is being created. The temporary copy is removed after UTM imports
the disk.

Configuration patches are prepared in a private temporary directory next to
the VM's plist, converted and validated, then atomically renamed into place.
A failed evaluation or conversion leaves the existing plist unchanged. VM
creation no longer tries to terminate the shared UTM application, and waiting
for a newly created VM to appear is bounded to 30 seconds. If this times out,
inspect UTM before retrying; registration may already have succeeded.

## Update A Running VM

Apply the current `.#utm` NixOS configuration to the running VM:

```sh
hey utm update utm
```

Use `--flake FLAKE#HOST` to update a VM from a host configuration outside this
checkout:

```sh
hey utm update utm --flake ~/Code/site-flake#utm
```

This does not recreate the VM. It builds the NixOS toplevel, copies the closure
to the VM, switches to it, moves the VM's system profile to that generation,
and refreshes boot entries:

```sh
sudo -n /nix/store/...-nixos-system-utm-.../bin/switch-to-configuration switch
sudo -n /nix/store/...-nix-.../bin/nix-env --profile /nix/var/nix/profiles/system --set /nix/store/...-nixos-system-utm-...
sudo -n /nix/store/...-nixos-system-utm-.../bin/switch-to-configuration boot
```

Only `--mode switch` is supported. `test`, `boot` and `dry-activate` are rejected
before any build or VM operation because this workflow persists the system
profile and may clean old generations.

Existing VM data is preserved. Normal NixOS activation semantics still apply:
configuration changes can restart services, remove declarative files, or change
system state that is managed by NixOS.

After activation, update verifies the result before returning success:

- SSH batch login works
- `/run/current-system` matches `/nix/var/nix/profiles/system`
- `/run/current-system` matches the generation that was just built
- SSH password authentication is disabled
- the passwordless activation sudo rule is usable

Before copying the closure, update verifies the existing host key and waits for
SSH batch login. The default wait is 180 seconds:

```sh
hey utm update utm --wait 300
```

If the locally built toplevel already matches both `/run/current-system` and
`/nix/var/nix/profiles/system`, update skips copying and activation, then runs
the same verification checks. If automatic generation cleanup is enabled by the
remote VM profile, update still enforces the configured generation retention.

## Compare Local And Remote State

Check whether the running VM already matches the selected host configuration:

```sh
hey utm diff utm
```

This builds the local toplevel and prints:

- local toplevel path
- remote `/run/current-system`
- remote `/nix/var/nix/profiles/system`
- whether each remote path matches local
- `up-to-date` or `needs-update`

Use an explicit flake target when the VM name and host name differ, or when the
host lives in another flake:

```sh
hey utm diff tang --flake .#tang
hey utm diff tang --flake ~/Code/site-flake#tang
```

## Roll Back A Running VM

Roll the VM back to the previous NixOS system generation:

```sh
hey utm rollback utm
```

Rollback does not recreate the VM and does not revert mutable application data.
It moves `/nix/var/nix/profiles/system` to the previous generation, switches to
that generation, refreshes boot entries, and runs the same activation checks as
`hey utm update`.

Use this when a recent `hey utm update` produced a bad NixOS generation but SSH
and activation sudo still work:

```sh
hey utm rollback utm --wait 300
```

If there is no previous system generation, rollback fails without changing the
running system.

Show the available system generations:

```sh
hey utm generations utm
```

This prints the current running system, the persisted system profile, whether a
rollback generation exists, and the profile generation list from the VM.

Clean old generations manually:

```sh
hey utm cleanup-generations utm
```

This uses the VM's configured `modules.profiles.vm-image.keepGenerations` value.
This delegates to the guest's existing Nix [`--delete-generations +N`
policy](https://nix.dev/manual/nix/2.31/command-ref/nix-env/delete-generations).
Unlike the exact-entry local `hey profile prune` planner, it also retains entries
newer than the active generation after a rollback; it can therefore keep more
than N entries. The guest's Nix version determines the native behavior.
To override it for one run:

```sh
hey utm cleanup-generations utm --keep-generations 5
```

Cleanup deletes older `/nix/var/nix/profiles/system` generations, refreshes boot
entries, and verifies the current system/profile state afterwards.

## SSH Access

VMs trust the configured user SSH CA through `services.ssh.trustedUserCAKeys`.
The host that owns the CA can sign the local user SSH key with a SOPS-managed
CA key, so login works without copying private keys into the VM.

The `utm` host also has a narrow sudoers rule for passwordless NixOS activation:

```sudoers
alice ALL=(ALL:ALL) NOPASSWD: /nix/store/*-nixos-system-utm-*/bin/switch-to-configuration switch
alice ALL=(ALL:ALL) NOPASSWD: /nix/store/*-nixos-system-utm-*/bin/switch-to-configuration boot
alice ALL=(ALL:ALL) NOPASSWD: /nix/store/*-nix-*/bin/nix-env --profile /nix/var/nix/profiles/system --set /nix/store/*-nixos-system-utm-*
alice ALL=(ALL:ALL) NOPASSWD: /nix/store/*-nix-*/bin/nix-env --profile /nix/var/nix/profiles/system --rollback
alice ALL=(ALL:ALL) NOPASSWD: /nix/store/*-nix-*/bin/nix-env --profile /nix/var/nix/profiles/system --list-generations
alice ALL=(ALL:ALL) NOPASSWD: /nix/store/*-nix-*/bin/nix-env --profile /nix/var/nix/profiles/system --delete-generations +[0-9]*
```

## Diagnostics

Show the current runtime state without changing the VM:

```sh
hey utm current utm
```

This prints the UTM status, resolved IP, `/run/current-system`,
`/nix/var/nix/profiles/system`, SSH password authentication state, and whether
the activation sudo rule is usable.

Run:

```sh
hey utm doctor utm
```

For first boot after recreating an image, doctor waits for SSH to become ready.
The default wait is 180 seconds:

```sh
hey utm doctor utm --wait 300
```

The doctor checks:

- UTM registration
- UTM status
- IP resolution through `hey utm ip`
- SSH batch login
- `/run/current-system`
- passwordless activation sudo rule

Doctor, updates, closure copies and other non-interactive SSH operations require
a trusted host key (`StrictHostKeyChecking=yes`). They never remove known-host
entries or their backups. A new or changed key therefore blocks them.

For a new VM, run `hey utm ssh VM`, compare its fingerprint with the VM console
or another trusted source, and confirm it interactively. Do this before `doctor`
or `update`; `--phases start,doctor` assumes trust has already been provisioned.
For a deliberately recreated VM with a changed key, first verify the new key
out of band. Then explicitly remove only the old entry for the resolved address
with `ssh-keygen -R <verified-address>` and reconnect to confirm the replacement.
If you use a custom known-hosts file, supply its path with `-f`. Never treat an
unexpected key change as proof that an entry is merely stale.

To open an SSH session using the same IP lookup:

```sh
hey utm ssh utm
```

To run one remote command:

```sh
hey utm ssh utm hostname
```

To build-check the image target without registering a VM in UTM:

```sh
hey check image utm
```

To check UTM command wiring without a running VM:

```sh
hey check utm-cli
```

To smoke-check the running VM:

```sh
hey utm check utm
```

This wraps `hey utm current utm`, `hey utm doctor utm`, and a remote
`hey info` invocation through `hey utm ssh`.

## Notes

`hey utm ip` intentionally keeps the original ARP/config.plist based lookup
implementation because it is the most reliable source for these UTM VMs.
