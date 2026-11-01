# Secret Hygiene

Use `hey doctor secrets` to find inline secret markers without printing secret
values. The command reports file and line numbers only. It scans host modules,
framework modules, and `.envrc`, including hidden and Git-ignored files within
those roots. Git metadata, `.direnv`, `node_modules`, `target` and result outputs
are excluded; directory scans do not follow symlinks. `HEY_DOCTOR_SECRET_PATHS`
can select explicit colon-separated scan roots. This is a local hygiene check,
not a replacement for scanning the exact publication export.

The scan includes common bootstrap leak patterns such as Tailscale auth key
markers, k3s node tokens, exported SOPS age keys, and Kubernetes-style
`password: <base64>` values in inline manifests.

Inline markers are reported as warnings, including matches in synthetic fixtures.
A scan error, such as a missing `rg` executable, is treated as a doctor failure.
Hey ignores ripgrep's user configuration and reads structured scan events.
Only escaped filenames and line numbers are reported; raw stdout, stderr and
parser errors are withheld on failure, including partially completed scans.

Provide bootstrap credentials through runtime secret files. Choose the secret
provider and secret names in your private consumer. The service modules accept:

- `modules.services.k3s-agent.tokenFile`
- `modules.services.k3s-server.agentTokenFile`
- `modules.services.tailscale.keyFile`

SAML and split OpenVPN credential files must be regular files no larger than
64 KiB. Symlinks used by secret providers are supported; the opened file is
checked. Reads have a five-second deadline and preserve meaningful whitespace.
EKS doctor uses the same SAML format validator and input limits as login. Dry
runs never open these files, and diagnostics never perform a login.
Git secret installation is limited to 1 MiB and a 45-second CLI operation;
oversized input leaves an existing destination intact. No values appear in
input-validation errors. These limits cannot force an uninterruptible kernel
operation to return; see the process-supervisor limitations in security.md.

## Protected SOPS sources on macOS

Darwin's `/run` can resolve through a group-writable `/private/var/run`.
That layout does not satisfy Nixi's protected traversal for privileged Git
copies and certificate inputs. Do not chmod system runtime directories to
work around this check.

Import the optional adapter **instead of** the upstream Darwin SOPS module:

```nix
hosts.laptop = {
  system = "aarch64-darwin";
  module = { ... }: {
    imports = [ inputs.nixi.darwinModules.sops-darwin ];
    config = { config, ... }: {
      sops.defaultSopsFile = ./encrypted-secrets.yaml;
      sops.age.keyFile = "/private/var/root/age/keys.txt";
      sops.secrets."git/token" = {};
      modules.shell.git.secrets.token.sourceFile =
        config.sops.secrets."git/token".path;
    };
  };
};
```

Supply `sops-nix` in the consumer's composed inputs; it is not a mandatory
framework dependency. Checkout consumers can import
`nixi/modules/optional/sops-darwin.nix` directly. The dedicated parent defaults
to `/private/var/lib/nixi-sops`; `nixi.sopsDarwin.directory` can select another
canonical directory beneath `/private/var/lib/`. All existing ancestors must
be root-owned, not group/world writable, and not symlinks. The preflight creates
missing directories but never chmods/chowns existing ones or follows aliases.

The adapter changes manifest construction before upstream validation, retaining
Nix dependency contexts. Upstream SOPS still mounts RAM-backed secret storage,
rotates generations and manages launchd. Secrets, `neededForUsers` secrets and
templates receive protected default paths; explicit `path` values remain native
overrides. Point privileged consumers at protected provider paths, not aliases
in a user-owned home or `/run`. Use each evaluated `config.sops.secrets.NAME.path`
instead of hardcoding locations. Git-copy and user-certificate activation run
after provider `mkAfter` installation (Nixi consumers use order 1600).

Identity filenames must be **quoted runtime strings**, never Nix path literals
or store references. For example, `sops.age.keyFile = "/path/to/keys.txt";`
does not import the file; `sops.age.keyFile = /path/to/keys.txt;` can copy its
contents into the Nix store during serialization. The adapter rejects such
values for age/GPG identity paths. Correcting a declaration does not remove
previous store copies or revoke an exposed key; those require a separately
reviewed cleanup and credential-rotation plan.

The adapter depends on upstream's manifest-builder interface and refuses
unexpected layouts. `checks.SYSTEM.sops-darwin` tests a pinned upstream source
with synthetic inputs, both activation stages, templates, overrides and native
manifest validation. Recheck compatibility when changing the consumer SOPS pin.
The check neither mounts a RAM disk nor decrypts real secrets; first activation
and boot behavior still require verification on the target Mac. Independent
certificate-renewal launchd jobs can start before SOPS at boot and retry on their
configured interval; launchd does not provide a dependency-order guarantee here.

Existing `/run` generations and old user-home aliases are not migrated or removed
automatically. Verify the new installation before separately retiring old mounts
and aliases. Changing a mount location must not become an unreviewed recursive
delete of a runtime directory.

## Optional homelab secret policy

The optional homelab profiles choose conventional SOPS names such as
`k3s/agent_token` and `tailscale/homelab_auth_key`. These are profile defaults,
not a requirement of the underlying service modules.
Override `agentTokenSecret` and `tailscaleAuthSecret` on either
`modules.profiles.homelab-k3s-server` or `modules.profiles.homelab-k3s-agent` to
select your own names; only those selected names are requested from SOPS.
The server's `podCIDR`, `serviceCIDR` and `advertisedRoutes` options likewise keep
topology decisions in the consumer. The separate `k3s-cilium.podCIDRs` option is
available when composing the Cilium recipe without the homelab preset.

`modules.profiles.homelab-secrets.useHostSshKey = false` selects `ageKeyFile`
and disables the provider's automatic age/GPG SSH host-key imports. Setting it
to `true` selects the profile's `sshKeyPaths` instead of an age identity file.
Explicit native `sops.age` and `sops.gnupg.sshKeyPaths` settings can override
these profile defaults. SOPS remains an optional consumer-supplied input.

For local editing, direnv sets `SOPS_AGE_KEY_FILE` when
`$HOME/.config/sops/age/keys.txt` exists. Avoid exporting `SOPS_AGE_KEY`
directly from `.envrc`; that puts the private key material into every process
environment started from the development shell. `hey doctor secrets` reports
that pattern as an inline secret marker.

Verify the migration with:

```sh
hey doctor secrets
hey check eval
hey check build analytics
hey sync build
```
## Git secret destination validation

`modules.shell.git.secrets.<name>.target` and Git profile file names must be
canonical relative paths below the Git configuration directory. Empty paths,
absolute paths, `.`/`..` components, repeated/trailing slashes, backslashes and
control characters are rejected during configuration validation. Secret and
profile destinations must be distinct and cannot replace the managed `config`
file. Existing configurations using such paths must be corrected before activation.
