# Secret Hygiene

Use `hey doctor secrets` to find inline secret markers without printing secret
values. The command reports file and line numbers only. It scans host modules,
framework modules, and `.envrc`, including hidden and Git-ignored files within
those roots. Git metadata, `.direnv`, `node_modules`, `target` and result outputs
are excluded; directory scans do not follow symlinks. `HEY_DOCTOR_SECRET_PATHS`
can select explicit colon-separated scan roots. This is a local hygiene check,
not a replacement for scanning the exact publication export.

The scan includes common bootstrap leak patterns such as Tailscale auth key
markers, k3s node tokens, exported SOPS age keys, Kubernetes-style
`password: <base64>` values, common crypt/bcrypt/Argon2 password-hash prefixes,
and PEM, OpenSSH, PGP and PuTTY private-key headers. These are marker checks;
unrecognized formats, binary contents and excluded files can still contain
credentials. A clean result does not certify that a tree is safe to publish.

Inline markers are reported as warnings, including matches in synthetic fixtures.
Use `hey doctor secrets --strict` for a gate: exit 0 means no markers in the
selected roots, 1 means findings, and 2 means an incomplete or failed scan.
Without `--strict`, findings retain exit 0; scan failures still exit 2.
`hey doctor --strict` forwards strict mode to its secret check and fails the
daily check if that subcommand fails. Empty scan roots are a failure.
Hey ignores ripgrep's user configuration and reads structured scan events.
Only escaped filenames and line numbers are reported; raw stdout, stderr and
parser errors are withheld on failure, including partially completed scans.

Provide bootstrap credentials through runtime secret files. Choose the secret
provider and secret names in your private consumer. The service modules accept:

- `modules.services.k3s-agent.tokenFile`
- `modules.services.k3s-server.agentTokenFile`
- `modules.services.tailscale.keyFile`

SAML and OpenVPN credential files must be regular files no larger than
64 KiB. Symlinks used by secret providers are supported; the opened file is
checked. Reads have a five-second deadline and preserve meaningful whitespace.
EKS doctor uses the same SAML format validator and input limits as login. Dry
runs never open these files, and diagnostics never perform a login.
The root-running OpenVPN adapter additionally requires protected root-owned
input traversal and a restricted config; see [its security contract](security.md#protected-openvpn-client).
For sensitive SAML usernames, leave `username = null` and supply `usernameFile`
as a runtime secret path. Private Nix source and overlays still produce public
store outputs when they embed an inline username.
Git secret installation is limited to 1 MiB and a 45-second CLI operation;
oversized input leaves an existing destination intact. No values appear in
input-validation errors. These limits cannot force an uninterruptible kernel
operation to return; see the process-supervisor limitations in security.md.

## Retiring installed Git secret copies

Removing a `modules.shell.git.secrets` declaration, changing its target or
disabling Git leaves previously installed copies in place. No activation scans
for or deletes undeclared files. Retirement does not revoke credentials or erase
source files, backups, filesystem snapshots or historical store exposure.

For future installations, explicitly opt into private runtime receipts:

```nix
modules.shell.git.secretTracking.enable = true;
```

This records each completed mode-0600 installation and installs the
`nixi-install-user-file` CLI for the selected user. Receipts default to
`${home.stateDir}/nixi/git-secret-copies`; filenames are the SHA-256 of the
relative secret target plus `.json`. `secretTracking.receiptDirectory` may
override the directory inside that user's home, without overlapping Git
destinations. Both receipt and lock are private mode-0600 user-owned files.
Receipts contain the destination, file identity/metadata, a content fingerprint
and a random review token, never source paths or credential contents. Keep them
private: fingerprints can reveal information if disclosed. No receipt or secret
content is generated during Nix evaluation or copied into a public store output.

Existing untracked copies are never adopted by a cleanup command. Enabling
tracking takes effect on the next explicitly performed installation; it does
not inspect or retire historical copies. A failed/interrupted receipt write can
leave an installed file without current provenance. Such a copy is retained,
and an older receipt cannot authorize its removal.

After removing a declaration and reviewing dependencies on the old copy, choose
its exact known receipt. Run as the recipient, without sudo:

```sh
nixi-install-user-file --preview-retirement /absolute/path/to/receipt.json
```

Preview creates no files. A `ready` result includes the destination and a random
`reviewToken`, without displaying file contents or fingerprints. Review that
specific destination before invoking the destructive step:

```sh
nixi-install-user-file --retire-receipt /absolute/path/to/receipt.json \
  --review-token TOKEN_FROM_THIS_PREVIEW
```

Apply revalidates the receipt, owner, private permissions, single-link regular
file type, device/inode, timestamps, size and content fingerprint. It refuses
unknown, modified, replaced, foreign, symlinked, hardlinked or unsafe files.
Reinstallation changes the token, invalidating an earlier preview. Only the
recorded copy is removed; sources, neighboring files, directories, receipts and
locks are retained. There is no recursive or broad cleanup operation.

The helper pins trusted non-symlink directories and runs entirely as the
recipient. Cooperating tracked installs/retirements share the receipt lock.
Stop applications or other writers first: the lock does not coordinate their
open descriptors, and this is not a boundary against a malicious process
running as the same user. A receipt does not prove a file is unused or that its
credential has been revoked. Reads are bounded and CLI operations have a
45-second deadline; error output omits parser input and credential values.

Apply first captures the destination in a private mode-0700 `.nixi-retire-*`
directory beside it, then checks the captured file again before unlinking.
Detected changes or handled failures attempt restoration without overwriting a
new destination. An uncatchable interruption can leave the payload in that
private directory. Preview reports `pending`; reinstallation and another apply
refuse to proceed. To recover explicitly:

```sh
nixi-install-user-file --restore-retirement /absolute/path/to/receipt.json
```

Restoration never overwrites a new target or recursively removes unknown files.
An unsupported captured file type or competing target requires manual review;
the quarantine is retained. Restoration can change file metadata, so a restored
copy may need a new reviewed installation before it is eligible for retirement.
Interrupted-process fixtures do not establish power-loss durability or secure
erasure. Native Linux/root/VM and consumer recovery acceptance remain separate.

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
hey doctor secrets --strict
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
