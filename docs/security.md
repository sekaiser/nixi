# Security and ownership boundaries

Nixi supplies mechanisms, not a trusted private inventory. Keep host descriptors,
site definitions, credentials, private endpoints and local Git history outside
the public release. Publish only a reviewed export with new Git history.

## Trust model

- Nix modules and overlays are trusted code. A hostile flake can run builders;
  source review and input pinning remain necessary.
- Enabling a service is an explicit host decision. Native NixOS/nix-darwin
  options remain authoritative for listening addresses, firewall and access rules.
- EKS metadata is configuration, not a command template. Schema version 1 accepts
  safe cluster keys and required nonempty names/profiles; optional strings may
  be null. Legacy unversioned metadata remains accepted; unknown versions fail.
  Exact cluster keys take precedence over AWS names. Duplicate AWS names require
  an explicit key and fail before routing or running commands. `eks env` and
  `eks shell` clear optional region/namespace variables when absent in the next
  cluster; they do not clear unrelated AWS credentials.
  Shell output uses LF only; status messages go to stderr. When routed through
  a bastion, `eks env`/`use` describe that remote host's paths, not local paths.
  Do not evaluate remote exports in a local shell; use `eks shell` to work there.
  Bastion commands require a previously trusted SSH key (including interactive
  commands). Enroll and verify the host separately before using EKS routing.
- UTM activation rights are administrative privileges. Permission to activate a
  user-built system closure is not a restricted non-root deployment capability.
- CA private keys are signing authority, not ordinary configuration. Prefer
  pre-signed host certificates or an external signer. Distributing a shared CA
  private key to hosts increases the impact of a compromised host.
- Privileged user-file copies require protected source traversal, not just a
  declared pathname. The installer pins root-owned, non-group/world-writable
  directories while resolving bounded symlink chains, then opens a checked
  regular file without following a final replacement symlink. Files may be
  root- or recipient-owned, but not group/world writable. ACLs granting untrusted
  write access are outside these POSIX-mode checks and must not be configured.
  Copies already running as the recipient cannot borrow root's read access.
  Darwin consumers with group-writable `/var/run` can explicitly select the
  [protected SOPS adapter](secrets.md#protected-sops-sources-on-macos); provider
  directories are checked without relaxing this boundary. Runtime identity
  paths must be quoted strings to avoid importing private key files into the store.
- Nixi runtime-secret options reject Nix path literals, contextual strings,
  store paths, and noncanonical absolute paths. This covers Git secrets, SSH CA
  keys, SAML credentials, OpenVPN files, K3s tokens, Tailscale auth keys and the
  homelab identity options; the optional Darwin SOPS adapter shares the same
  validator. Public keys and pre-signed certificates may remain store-backed.
  Use `"/run/secrets/name"` or a secret provider's runtime `.path`, never
  `"${./private-key}"`. Validation cannot undo a store import already triggered
  by interpolation, nor detect a runtime symlink into the store. Native provider
  options outside these adapters remain the consumer's responsibility.
- Git secret and managed profile destinations must be disjoint, including
  ancestor/descendant collisions and the reserved main `config` file.
- Certificate preparation uses the same protected source and atomic replacement
  primitives. User public-key reads happen only after dropping to the recipient;
  CA reads stay privileged. Reads are limited to 1 MiB and each operation has a
  45-second deadline. Invalid certificate type/key/signature/validity/principals
  fail before replacement. Host destinations also require protected, no-follow
  ancestor traversal. The Python wrappers clear Nix-specific import/executable
  environment overrides before startup, in addition to isolated mode.

## Generic runtime versus optional infrastructure

The composition library, neutral modules and Hey command dispatcher form the
generic mechanism. EKS, UTM, homelab and Cilium VM profiles are optional adapters
or presets; they are not prerequisites for a consumer's host configuration.
UTM commands require UTM at execution. EKS commands require generated AWS
metadata and the corresponding tools. Cilium VM disk policy requires an explicit
Disko import (or the documented legacy target adapter). These presets do not
belong in the minimal getting-started configuration.

The documented host descriptors and composition entry points are the intended
public API. Runtime Janet helpers, generated activation scripts and store paths
are implementation details, not extension contracts. Optional infrastructure
adapters should be treated as experimental until validated against the consumer's
own platform and infrastructure. Pin Nixi revisions and review migration notes;
this distinction does not imply a versioned compatibility guarantee yet.

For key/certificate-only Linux SSH defaults, opt into:

```nix
modules.profiles.secure-ssh.enable = true;
```

This disables password and keyboard-interactive authentication and root login.
Provision and verify an authorized non-root key before switching. Explicit
native settings can override these defaults. No existing host is opted in
automatically, and the profile does not provide keys or restrict network reachability.

## Verification safety

Build [sandbox policy](https://nix.dev/manual/nix/2.31/command-ref/conf-file.html#conf-sandbox)
belongs to the consumer. Set `nix.settings.sandbox = true`
in your host policy when supported and verify your builds before activation.
`hey doctor nix` reports the client-effective scalar and warns for disabled or
relaxed sandboxing; it does not verify daemon enforcement. Sandboxing is not a
permission boundary for activation scripts, interactive development shells or
programs you run from a flake. Pin and review dependencies even with it enabled.

Local Hey sync activation, rollback, generation removal and pruning coordinate
through the same runtime-directory lock. Removal checks its active-profile
snapshot again before deletion. This only coordinates cooperating Hey processes
using the same runtime directory: other users, remote UTM operations, direct Nix
commands and external rebuild tools are not covered. Do not run those operations
concurrently. Nix's own operation-level locks do not make a multi-command Hey
workflow atomic. Crashes can leave a stale Hey lock; verify no operation is active
before removing it. No automatic lock stealing is performed.

Zsh completion excludes insecure `fpath` entries on every initialization; cached
startup does not skip ownership checks. Completion cache files and their parent
chain must be protected before loading executable dumps. Unsafe caches are not
repaired automatically: completion runs without reading or writing a dump.
Root-owned sticky temporary-directory ancestors are supported, but the cache
directory itself must be owned by the user and not group/world writable.
Legacy startup cache cleanup runs only as the Home Manager user and removes
named compiled siblings of Nixi-managed files, not arbitrary user scripts.
The compatibility `hey.cache` initializer no longer persists executable output.
It generates small startup snippets afresh and evaluates them only after a
successful generator exit. Legacy cache files and compiled siblings are neither
loaded nor automatically deleted. Only explicitly selected generators run.

Runtime probe capture limits each output stream to 8 MiB by default. Exceeding
the limit fails with status 125 instead of accepting truncated data; internal
callers can pass an explicit positive byte limit to `process/capture`.
Nix JSON/raw evaluation and captured build-result paths use the same capture
primitive and Nix-built native supervisor. Set `HEY_NIX_CAPTURE_LIMIT` to a positive byte count when a
legitimate result exceeds the default. Nix builds and evaluations have no short
probe deadline; build stderr remains streamed, not buffered. Bootstrap and
context probes have ten-second deadlines. `process/probe` supplies a ten-second
default for diagnostics, rejecting nonpositive or nonfinite deadline overrides.
Tmux, direnv, SSH and general doctor captures use it; explicitly longer probe
deadlines are retained. Tmux stops probing on timeout or output overflow rather
than repeating stalled calls. Foreground and interactive execution are unchanged.

Captured commands run in a dedicated process group, with closed stdin. A native
supervisor sends TERM, CONT and then KILL on timeout, overflow, cancellation and
normal command exit, cleaning up remaining in-group descendants. A private
lifetime pipe also triggers cleanup if Hey is killed abruptly, including SIGKILL.
The direct child is reaped only after the final group signal, preventing recycled
PID/group targeting. Buffers and cleanup waits are bounded. argv, environment,
cwd and command status are preserved. See the
[supervisor contract](../tools/process-supervisor/README.md) for protocol and timings.

This is not process isolation: descendants that deliberately leave the group,
work submitted to existing daemons, signal-permission changes, an uninterruptible
kernel task or SIGKILL of the supervisor itself need stronger service/OS
containment. No privileged service is installed. Darwin's zombie-only EPERM
case is checked using a bounded kernel group snapshot; process ancestry scans
are never used to construct kill targets. Native lifecycle checks run in both
platforms' public CI jobs; detached test processes still need explicit cleanup.

`hey context`, `hey doctor sync` and all `hey sync` paths (including normal,
explain, verbose and dry-run execution) never log raw `NIX_CONFIG` themselves.
They report only whether it is set, because it may contain access
tokens or authenticated URLs. This is not a universal log sanitizer: inspect
external tools' output and other diagnostics before sharing support reports.
Store selection is consumer policy, and optional `nom` is not a health
requirement. If requested but unavailable, Hey warns and uses ordinary Nix.

SSH and agent process diagnostics distinguish a successful empty result from a
failed probe. Process/socket probe failures, timeouts and output-limit failures
prevent a passing result. `lsof` exit 1 is treated as no matches only when both
output streams are empty. Process probes have ten-second deadlines; Nix process
diagnostics use one snapshot per run.
All process diagnostics share an explicit PID/PPID/state/elapsed/command parser;
malformed snapshots fail rather than pretending parent information is absent.
Zed extension discovery likewise requires a successful probe before comparing
installed and expected extensions; partial output cannot establish success.

Agent configuration checks parse TOML and safe YAML rather than searching text.
Commented entries are not configuration; quoted TOML keys work. Missing,
malformed, disabled and mismatched entries fail the check. Config files are
limited to 1 MiB and five seconds; parser errors never echo their input.
This validates syntax and the explicitly expected entries, not each vendor's
complete configuration schema or an MCP server's runtime health.
Packaged Hey includes its Python/TOML/YAML runtime. Source checkouts use
`HEY_RUNTIME_PYTHON` from `nix develop`, or Python 3.11+ with PyYAML and
Cryptography on PATH. The shared runtime is defined by `packages/hey-python.nix`.

SSH doctor checks default public certificate paths and the managed host CA file.
Malformed installed material fails the command, including in quiet mode;
absent optional files are reported as not installed. Certificate signature,
type and current validity are checked, not remote issuer trust or authorization.
The static client-config check handles unconditional Includes and first-value
precedence, without executing `Match exec` or any other SSH command. Conditional
trust/Includes, Match and dynamic paths are unverified (nonzero exit), not
certified. Config input is limited to 1 MiB total, 64 files and 16 nested files,
with a five-second deadline. See [SSH diagnostics](ssh.md#diagnostics).

UTM verification uses the remote OpenSSH parser (`sshd -T -G -C ...`) for the
current session's user and source/destination addresses and port. `-G` exits
before host-key loading; no extra sudo rights are required. Includes and Match
rules are applied. Unreadable configuration, unsupported flags and UseDNS=yes
fail closed: the latter's server-resolved Match Host name cannot be recovered
reliably from SSH_CONNECTION. This checks on-disk `/etc/ssh/sshd_config` for that
connection, not every account/address or an independently configured daemon.

The untracked-file check examines non-ignored files beneath the selected consumer
directory, including arbitrary module/package layouts, without scanning sibling
directories in a parent repository. It does not claim that every listed file is
a Nix input. Git errors fail the check; a non-Git consumer explicitly skips it
because the Git-backed-flake omission rule does not apply there.

Use `python3 test_tools/run_cli_tests.py` for the behavioral suite. Each test runs
serially in a separate process group, with a 60-second deadline, bounded captured
output, a worker file-descriptor limit and group cleanup. Execution stops at the
first failure. Detached processes that create their own sessions require their
test-specific cleanup; process groups are not a security sandbox.
The `cli-contracts` check also runs Janet unit and CLI contracts serially through
the same supervisor. Each suite has a five-minute deadline, a 2 MiB output cap,
and a 256-descriptor ceiling, with a temporary home/store and mocked process,
SSH and VM commands. Its individual command captures have 30-second deadlines.
The Python runner uses the same native supervisor and lifetime-pipe contract;
it never signals a process group using a possibly reaped worker PID. Its output
limit is 2 MiB combined across stdout and stderr.

UTM IP discovery is passive unless `--scan` is explicit. Scans are limited to
eight supervised pings at a time and share the discovery deadline with every
UTM, AppleScript and ARP probe. Dry runs execute no discovery commands.

The earlier system-wide file-handle exhaustion has not been attributed to a
specific component. These controls reduce exposure; they do not establish its
root cause. Run broad integration tests in disposable hosts, not beside valuable
interactive work, until that investigation is complete.

## Publication gate

Review manually pinned dependencies as well as `flake.lock`; see
[dependency maintenance](dependencies.md). Content hashes establish which bytes
were selected, not whether that version is still supported or secure.

Run the allowlist audit and an independent secret scanner on the exact export.
Then build/evaluate that exported tree on a clean runner without the private
workspace mounted. Scan staged files again before the first public commit.
Hash verification detects content drift; it is neither a signature nor proof
that a reviewer recognized every sensitive value. Never upload private scan
patterns, scan reports, personal system closures or their build logs.
