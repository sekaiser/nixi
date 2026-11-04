# Hey Feedback Loops

`hey check` groups local validation commands by cost:

```sh
hey check unit
hey check cli
hey check utm-cli
hey check framework
hey check [--flake FLAKE] flake
hey check [--flake FLAKE] eval [HOST]
hey check [--flake FLAKE] build HOST
hey check [--flake FLAKE] image HOST
hey check all [HOST]
```

Use `hey check unit` after changing the Janet libraries or zsh helper scripts.
It runs the Judge tests under `test/hey` with isolated XDG directories.

Use `hey check cli` after changing Janet command wiring. It runs cheap dry-run
checks for generic commands such as `sync`, `repl`, and `watch`.

Use `hey check utm-cli` after changing `hey utm ...` command wiring. It validates
UTM dry-run paths and intentionally does not require a running VM.

Use `hey check flake` after changing flake checks under `checks/` or package
sources covered by those checks. It builds all flake checks for the current
system. Use `hey check --flake ./fleet flake` for an external host flake.

Use `hey check eval` after changing Nix modules, host composition, or the
`mkFlake` framework. It evaluates the consumer's declared Darwin and NixOS
system derivations without building them. Missing platform/check outputs are
allowed; genuine evaluation errors still fail. Use
`hey check eval HOST` or `hey check --flake ./fleet eval HOST` when you
only need to inspect one host.

Use `hey check build HOST` for a specific host closure build, and
`hey check image HOST` for a generated qemu-efi image build.

Use `hey check all` to run the consumer's flake and evaluation checks.
`hey check all HOST` keeps the final eval step scoped to one host.
Nixi maintainers should additionally run `hey check framework`, `hey check unit`,
`hey check cli`, and (on macOS) `hey check utm-cli`. The `framework` command checks
Nixi's exported module/check contract at the embedded framework root, never the
consumer's outputs. Unit and generic CLI fixtures use
unique temporary directories with cleanup. The generic CLI suite still depends
on local platform tools and runtime state; it is not a hermetic host test.
The `cli-behavior` flake check separately runs isolated project/consumer tests.
Suite runners and command-wiring fixtures live under `test/cli/`; they are
loaded on demand, not on every Hey invocation. Dry-running a suite reports
the selection without creating fixtures or launching test commands.

For an external host flake, pass the composition root explicitly:

```sh
hey host list --flake ./fleet
hey check --flake ./fleet eval HOST
hey check --flake ./fleet flake
hey sync --flake ./fleet#HOST --explain
```

The installed wrapper embeds the framework source location separately from the
consumer checkout. `--flake` selects the consumer, not where to find Nixi's
runtime. A consumer needs `flake.nix`, not a prescribed `hosts/HOST` directory.
UTM is optional and is not involved in ordinary `hey sync` activation.

Command registration records source paths without importing implementations.
`hey --help`, command help and `hey which COMMAND` do not initialize command
modules. Execution imports the selected command and its dependencies; a broken
optional module fails when selected without blocking unrelated commands.
Help reads the script header, so successful help does not establish that the
implementation or its tools are usable. Missing selected modules fail explicitly;
they do not fall back to a similarly named executable on PATH. The core Hey
runtime remains required, and imported modules remain trusted executable code.

## Preview build cost before activation

```sh
hey sync plan
hey sync plan --flake ./fleet#HOST
```

This runs `nix build --dry-run --no-link` for the selected local-platform system
target, without sudo, activation, lock updates or result links. Nix reports the
derivations to build, cache downloads and sizes when available. These are build
tasks/store outputs, not application counts; configured remote builders can also
perform builds. Cache/store state may change before the real sync. It is not an
elapsed-time estimate and does not preview Homebrew downloads or activation work.

Inputs may still be fetched and evaluation can write source/derivation metadata
to the Nix store. Import-from-derivation is disabled so a preview cannot start
evaluation-time builds; configurations requiring it fail rather than silently
falling back. Flakes/modules remain trusted code, and diagnostics may expose
paths or configuration details. Keep private-host output local. `hey -! sync plan`
or `hey sync plan --explain` prints the command without the Nix query.
Neither preview nor ordinary sync scans CVEs or updates pins.

## Local sync builds and activation

Run `hey sync` as your normal user. Evaluation and builds use that user's Nix
configuration and private-input access, with `NIX_PATH` cleared and lock updates
disabled. Impure evaluation remains explicit for existing consumer configurations.
The build result is captured as one store output and temporarily GC-rooted while
activation runs. Normal sync uses Nix directly for its JSON result; build-only
commands still honor the optional `nom` preference.

Only activation uses sudo. The packaged `nixi-system-activate` helper receives
fixed candidate, selected-profile and running-system store paths. A source
launcher builds that helper as the caller when needed. The privileged invocation
starts with a clean environment; caller `NIX_CONFIG`, SSH agents, `DOTFILES` and
Python import overrides are not forwarded. The helper uses pinned Nix programs,
ignores root's per-user Nix configuration and operates on the default local system
profile. No root flake evaluation, realization or private-input fetch is requested.

| Action | Platform | Effect after building |
| --- | --- | --- |
| `switch` (default) | Linux/macOS | Select and activate the candidate; Linux also updates boot configuration |
| `boot` | Linux | Select the candidate for boot, retaining the running system |
| `test` | Linux | Activate without changing the selected profile |
| `activate` | macOS | Activate the selected flake's built output without changing the profile |
| `dry-activate` | Linux | Run the candidate's native activation preview as root |

`hey -! sync` and `--explain` only print the plan; they do not invoke Nix, sudo,
activation, locks or temporary build roots. `hey sync build` and `check`/`ch`
remain unprivileged and do not activate. VM build actions select the NixOS VM
output and write `result-vm`; cross-platform builds need appropriate Nix builders.

Normal sync accepts `--max-jobs`/`-j`, `--cores`, `--option NAME VALUE`, `--offline`,
`--keep-going`/`-k`, `--keep-failed`/`-K`, `--print-build-logs`/`-L`, `--show-trace`
and `--fallback`. These options apply only to the user build. `--fast` is a
compatibility flag: direct builds never re-execute a rebuild frontend. Unsupported
remote targets, custom profiles, specialisations, bootloader flags and lock-update
options fail explicitly; no privileged rebuild fallback is used. `--host` selects
configuration for the local machine, not an SSH destination. Existing numeric
generation rollback remains a separate operation; `sync --rollback` delegates to
`hey profile rollback`.

The helper verifies realized store paths, protected executables and unchanged
selected/running checkpoints before mutation. A protected global lock serializes
new helper transactions across users; the existing Hey profile lock also covers
the caller's build and activation. Failed activation attempts restore the fixed
profile/running outputs and Linux boot configuration when safe. A conflicting
external change or failed recovery is reported for manual recovery. Exit status
is preserved. This does not undo application data, Homebrew changes or arbitrary
activation-script effects. An uncatchable kill can interrupt recovery and leave
temporary roots; these are not automatically pruned.

Supported activation assumes an existing local system and the modern Darwin
activation layout. Legacy `activate-user`, bootstrap installations and other
profiles require their own reviewed procedure. Do not run external rebuild,
rollback or pruning tools concurrently: they do not share the helper's lock.
Synthetic tests cover both platform command plans, not real privileged service
or boot behavior. Disposable native acceptance and private-input compatibility
remain release gates. Activating a user-built closure still grants administrative
authority to its scripts; this is not a sandbox or a new passwordless sudo grant.

## Dependency maintenance

`hey pull nixpkgs nixpkgs-darwin nixpkgs-unstable` updates selected consumer pins;
it does not deploy them. See [dependency maintenance](dependencies.md) for the
upstream-first policy, override review reports and opt-in automation.

`hey security scan /nix/store/HASH-NAME --json` invokes an explicitly installed
`vulnix` for that target and its build dependencies. Use a real store output or
derivation path; no implicit whole-host scan, package installation or deployment
occurs. Advisory data is downloaded/cached by the scanner. Scanner exit status
is preserved, including errors. Output and diagnostics are not universally
redacted: private host/package names and store paths can appear. Keep them local.
Dry-run does not invoke the scanner. Findings are heuristic and need review.

Host, check and image names are individual Nix attribute segments. Dotted names
such as `node.example` and names containing spaces are quoted automatically;
pass the literal name to Hey (`hey check eval node.example`). Empty names and
names containing double quotes are rejected because Nix's CLI selection-path
syntax cannot represent them. This quoting is not shell syntax.

`hey info ip` reports the local IPv4 address. On Linux it asks the kernel to
resolve the route to `1.1.1.1` and returns the selected source address, including
when the default route has no explicit `src`. This lookup sends no packets;
policy routing and VPNs can affect the result. Missing routes or source addresses
fail explicitly. macOS uses the default interface and `ipconfig`; `-w` uses DNS
to discover the public address.

`hey template init NAME [DIR]` accepts names from `hey template list`, not source
paths. Template directories must resolve inside the framework's template root;
parent traversal and symlinks outside that root are rejected. The destination is
a local directory and must be empty or absent. Copied files and directories are
owner-writable even when the template lives in the read-only Nix store; executable
bits are preserved. Use `./-name` for a destination
whose name begins with a dash. Dry runs validate these boundaries without copying.

`hey.enable` installs the core CLI runtime with an explicit command set: `hey`
and `myip` (`hey info -r ip`). It does not put the framework's source `bin/`
directory on the shell PATH or install the retired desktop/media helpers.
The development shell intentionally exposes the checkout's source entrypoints;
the release allowlist reviews exported sources, including separately packaged
optional utilities such as `tmuxsel`. Consumer commands belong in their own
packages or PATH; existing host/desktop dispatch remains available.

Captured, noninteractive commands use a Nix-built native process supervisor.
The installed launcher pins its path; the development shell supplies the matching
helper for source entrypoints. When upgrading an older checkout, enter
`nix develop` before running source `bin/hey`/`nixi/bin/hey` and rebuilding your
host. Direct Janet invocations outside that shell need `HEY_PROCESS_SUPERVISOR`
pointing at the built helper (or `nixi-process-supervisor` on PATH). There is no
unsafe direct-child fallback. Command stdin is closed for captures; commands
that need user input must use foreground execution. See
[the lifecycle and containment limits](security.md).

The launcher and development shell also pin Python 3 with PyYAML and Cryptography
for bounded credential reads, agent config and public SSH material checks. Direct source
invocations need `HEY_RUNTIME_PYTHON` pointing at that interpreter, or Python
3.11+ with those dependencies on PATH. Parser failures never print configuration values.

Enable `hey.development.enable` for
GCC, cached-nix-shell, nix-prefetch-git, just, process-compose and watchexec;
enable `hey.diagnostics.enable` for jq, DNS utilities, dash, file,
nix-output-monitor and wget, plus lsof and procps on Linux (macOS supplies
the process and socket probes). `hey.extraPackages` accepts additional packages.
The workstation profile defaults both tool groups on. Individual workflows
still need their corresponding tools, whether installed by these options,
another module, or a development shell.

The Hey package's `homeBinDir` argument defaults to `null`, meaning the runtime
user's `$HOME/.local/bin`. Explicit strings are literal paths, not shell code;
an explicit `"$HOME/..."` is not expanded. A nonempty `XDG_BIN_HOME` takes precedence.

Use dry-run mode before switching a real host:

```sh
hey -! check --flake ./fleet eval HOST
hey -! check --flake ./fleet build HOST
hey sync --flake ./fleet#HOST --explain
```

External dispatch (`hey exec`, `hey host COMMAND`, and executable shorthands)
preserves the child command's exit status. With `-!` or inherited `HEYDRYRUN=1`,
Hey prints the invocation without starting the command; custom scripts need not
implement their own dry-run convention to make these dispatch paths safe.

## Tmux

The tmux module installs the standalone `tmuxsel` package, independently of Hey.
On macOS, `modules.shell.tmux.autoAttach = true` invokes its selector at shell
startup outside supported editor terminals. Override `sessionSelector` with a
package whose `meta.mainProgram` names your preferred selector. Exit 0 ends the
outer shell after attachment; a nonzero exit keeps it open. A missing executable
warns instead of preventing shell use. `tmuxsel` retains its numbered-session,
new-session-name and `nil` choices; it is also available directly from PATH.

Tmux assets resolve from `TMUX_HOME`, falling back to `$XDG_CONFIG_HOME/tmux`
or `$HOME/.config/tmux`. This includes popups, pane helpers, generated
initialization and `tmux.local.conf`. The helper shim uses `DOTFILES_BIN/hey`
when set, otherwise `hey` on `PATH`; it does not assume a consumer checkout.
Popup bindings pass a pane ID, and the helper queries the directory as data.

`hey tmux doctor` checks server reachability and whether effective options and
key tables can be read. It reports configuration drift as a warning, not a
failure, and does not require a particular theme, prefix, status width or
binding layout. `hey reload tmux` clears its temporary initialization-suppression
flag even if sourcing the configuration fails, preserving the original error.

## Project Workflows

`hey project` is a thin adapter over project-native files. It does not replace
flakes, `direnv`, `just`, language tools, or service orchestrators.

The preferred project shape is:

```text
project/
  flake.nix
  .envrc
  process-compose.yaml  # optional
  justfile              # optional
```

Common commands:

For input updates, quote patterns: `hey pull '*' '!nixpkgs'` updates matching
inputs except `nixpkgs`. Exclusions are applied after all inclusions regardless
of argument order. Exclusion-only requests start with all inputs. An empty
selection fails rather than updating everything. Dry-run previews show the
requested patterns without resolving the input metadata.

```sh
hey project status
hey project shell
hey project check
hey project test
hey project ci
hey project up [PROCESS...]
hey project down
hey project logs [PROCESS]
hey project services
```

`hey project shell` enters `nix develop` when a flake is present, with `.envrc`
as a fallback. `hey project ci` prefers `just ci`, falls back to
`nix flake check`, and finally runs the detected `check` and `test` commands.

For `check` and `test`, an explicitly declared matching Just recipe wins.
`check` then prefers `nix flake check` over a supported language command;
`test` goes directly to the language test runner. A flake can define no tests,
so its presence alone never satisfies `test`. To use flake checks as your test
suite explicitly, declare a Just `test` recipe that runs `nix flake check`.
Use `hey -! project check` or `hey -! project test` to preview the selected
command without executing it. A Justfile without that
recipe does not block the remaining fallbacks. Unsupported workflows fail with
an explanation; a Git status listing is not a successful check or test. Nested
projects use their nearest project definition within the repository boundary.
Definitions include `.envrc`, `gradlew`, and either process-compose filename,
so shell-only and service-only subprojects do not inherit the parent project.
Outside Git, discovery searches parent directories up to the filesystem root;
when no definition exists, it uses the original working directory.
Cleaning verifies the entire removal plan first and refuses tracked source files
or a failed Git check, including when no Git repository is available.

`hey project up/down/logs/services` use `process-compose.yaml` or
`process-compose.yml` when present. Nixi uses a per-project Unix socket at
`.nixi/process-compose.sock`, so different repositories can run local services
without sharing the default process-compose server endpoint.
Dry runs do not create its `.nixi` directory.

`hey project watch` (also `hey dev watch`) watches the detected project root
and runs its fast validation command. It shares the argument-safe Watchexec
runner with `hey watch`: spaces and shell syntax in paths remain literal.

## Cache cleanup

`hey clean [all|zsh|nix|k9s|cache]` removes only the selected known cache paths.
Preview with `hey -! clean`. All Hey user-state roots must be absolute directories,
not `/`, and must not contain `..` components. Empty XDG variables use their
HOME-based defaults; an unset or empty HOME is rejected. Invalid roots fail before
cleanup starts. Zsh's legacy completion files follow `XDG_CONFIG_HOME`, and final
symlinks are removed without traversing their targets.

## System rollback and generation retention

`hey sync rollback GENERATION` and `hey profile rollback GENERATION` activate
the selected system generation, not just its profile symlink. macOS delegates
to `darwin-rebuild --switch-generation`; Linux switches the profile and runs
that generation's `switch-to-configuration switch`. Both verify the resulting
`/run/current-system`. Preview with `hey -! sync rollback GENERATION`.

Local profiles support an explicit keep-N plan:

```sh
hey -! profile prune --keep-generations 10        # preview system profile
hey profile prune --keep-generations 10          # apply the displayed plan
hey profile prune --user --keep-generations 10   # current user's profile only
```

The active generation is always retained and counts toward N, even after a
rollback. The other retained entries are the newest existing generations;
numbering gaps do not count. Fewer than N entries means no deletion. A positive
integer is required; Nixi does not set an automatic local retention policy.
Planning and deletion share Hey's profile-removal lock; do not concurrently
modify the profile using other tools. System pruning verifies the running
system matches the selected profile and refreshes Linux boot entries.
Explicit system `profile rm` uses the same deletion-and-refresh helper, and GC
deletion also takes the profile-removal lock. A system keep-N prune refreshes
Linux boot entries even with no remaining deletions, so retrying after a failed
boot refresh reconciles the menu. A refresh failure stops subsequent collection.
Pruning does **not** collect store paths or activate a different generation.

UTM guests already have separate `keepGenerations` policy and
`hey utm cleanup-generations --keep-generations N`; those interfaces are unchanged.

`hey gc` refreshes boot entries only on Linux. macOS does not have a NixOS
`switch-to-configuration` boot hook.

`hey gc -d` deletes old generations only from the current user's Hey profile.
`--system` selects only the system profile; `--all` selects both. It prunes
explicit profile paths and refreshes boot entries before running store-wide
garbage collection. It never uses `nix-collect-garbage -d`, which can discover
and prune other profiles. Use `hey -! gc --system -d` to preview the scope.
Do not add `-d` when collecting after a keep-N prune: it deletes all old entries.

## Build

`hey build iso` builds the selected host's ISO into `./result-iso`. It never
updates the system profile or activates anything. Preview with `hey -! build iso`.

`hey build` builds the `hey` package from the framework used by the running
executable, not from the consumer flake. Consumers need not re-export any
framework packages. `hey build -a` also builds its pinned `hey-janet-deps` package.
Result links stay in the caller's working directory: `result` for Hey and
`result-hey-janet-deps` for its dependencies. Neither command changes the
framework's lock file. Use the checkout's `bin/hey` to build a modified framework.

The framework flake also exposes `hey` as the default package, so from a Nixi
checkout plain Nix usage works:

```sh
nix build .
```

## Package Search

`hey search` wraps `nix search` with nixpkgs as the default package set:

```sh
hey search ripgrep
hey search rust analyzer
hey search --from nixpkgs#gnome3 vala
hey search --json process-compose
```

Use `--from INSTALLABLE` when you want to search a narrower package subtree or
another flake installable. Dry-run mode shows the exact `nix search` command.

## Doctor

`hey host explain HOST --flake ./fleet` reads the evaluated flake output,
including enabled module/profile flags and profile classification fields. It
does not serialize arbitrary profile settings or import files under an
assumed `hosts/HOST` layout; inline, flat, and grouped inventories work alike.
Evaluation failures are errors, not empty metadata.

Installed `hey/info.json` likewise exports an explicit runtime contract rather
than all profile options. Profiles expose only metadata required by CLI consumers
(for example, VM-image retention settings). Consumer-defined `hey.info` entries
are still supported; do not place credentials in this public runtime metadata.

`hey host doctor HOST --flake ./fleet` checks that this metadata evaluates.
Add `--storage` to opt into the opinionated Nixi storage policy checks: bounded
Nixi journald settings, TRIM, `noatime`, and VM-image cleanup defaults. These are
not universal NixOS validity requirements or substitutes for a full host build.

`hey doctor` runs local health checks for the active machine:

```sh
hey doctor
hey doctor env
hey doctor nix
hey doctor secrets
hey doctor secrets --strict
hey doctor shell
hey doctor sync
```

`hey doctor nix` warns when the client-effective `sandbox` setting is `false` or
`relaxed`. It queries only that scalar, withholding stderr and unexpected values;
it never dumps the complete Nix configuration. Failed or unrecognized queries
fail the diagnostic. Recognized unsafe settings warn without failing it. A `true`
result is not an attestation of daemon enforcement or permission to trust an
unknown flake. Dry-run mode only prints the intended query.

With `--verbose`, Nix doctor reports three identities separately: the Nix client
selected by the caller's original PATH, the client selected by Hey's managed
execution paths, and the connected daemon's reported version. Client paths are
resolved through symlinks; process-name version labels are shown separately and
are not used as daemon version evidence. Daily doctor preserves the parent's
caller PATH when it starts the Nix diagnostic child.

Different clients or versions produce a warning, without declaring either one
vulnerable or outdated. Missing clients, denied connections, failed probes,
invalid replies and unreported daemon versions fail the diagnostic. Only parsed
identity fields are printed; raw version/store-info output and errors are
withheld. The daemon probe uses Hey's client with
[`nix store info --store daemon --json`](https://nix.dev/manual/nix/2.34/command-ref/new-cli/nix3-store-info).
This reports the local daemon explicitly, independently of a consumer's default
store selection. No profiles or configuration are changed.

Use `hey doctor secrets` to find inline secret markers without printing secret
values. `--strict` exits 1 on findings; scan failures exit 2 with or without it.
This is a limited marker scan, not proof that credentials are absent. See
[secrets.md](secrets.md) for coverage and the SOPS migration contract.
The default daily checks and `hey dev doctor` only inspect optional shell/editor/
agent subsystems advertised as enabled by the generated host metadata.

Use `hey ssh doctor` to inspect SSH certificate state and stale SSH
processes/tunnels. See [ssh.md](ssh.md) for the SSH certificate model.

## Watch Mode

`hey watch` wraps common checks with `watchexec`:

```sh
hey watch cli
hey watch utm-cli
hey watch flake
hey watch eval [HOST] [--flake FLAKE]
hey watch tmux
hey watch run COMMAND [ARGS...]
```

Use `hey watch eval` while editing Nix modules, host composition, or `mkFlake`
wiring. Prefer `hey watch eval HOST` or
`hey watch eval HOST --flake ./fleet` when the change is host-specific.
Use `hey watch cli` while editing Janet commands, `hey watch utm-cli` while
editing UTM command code, `hey watch flake` while editing Nix flake checks or
checked package sources, and `hey watch tmux` while editing tmux assets or
helpers.

Use `hey watch run` for one-off loops, for example:

```sh
hey watch run hey tmux doctor
```

All watch commands support dry-run mode:

```sh
hey -! watch cli
```

`watch eval` and `watch flake` watch the selected consumer directory, including
when invoked from another checkout or a subdirectory. `--flake` accepts a local
directory or `path:` directory, not remote or revision-qualified references.
`watch cli`, `watch utm-cli` and `watch tmux` watch the framework used by the
running Hey executable; use the checkout's `bin/hey` while developing Nixi.
`watch run` watches the current directory without an extension filter. Evaluation
also observes lock files; flake checks include Python and Janet sources.

Commands run directly, without an implicit shell. Arguments containing spaces or
shell syntax stay literal. For intentional shell operations, invoke a shell
explicitly, for example `hey watch run sh -c 'command1 && command2'`. Dry runs do
not require Watchexec or an existing target directory and do not start a watcher.

`hey direnv status` reports the nearest `.envrc` and preserves the underlying
command's output and exit status. `hey direnv doctor` fails when direnv cannot
report its status; missing optional config or `.envrc` files remain warnings.
Dry-running these diagnostics does not execute direnv.

## Hooks, input overrides, and shell plugins

`hey hook EVENT` stops at the first failing script and exits unsuccessfully.
Only successful completion is deduplicated; a failed attempt can be retried
without `-f`. Deduplication is checked inside the event lock. `hey reload` also
fails when a reload hook fails. Generated `hey.hooks` scripts use `errexit` and
`pipe_fail`; mark an intentionally ignored failure explicitly with `|| true`.
Hook names without a two-digit priority prefix receive `50-`. User hook files
run in lexicographic filename order, so priority prefixes determine execution
order regardless of filesystem creation order. Resulting filenames
must be unique within a phase: defining both `task` and `50-task` is an evaluation
error naming both definitions. Rename one (for example, `60-task`) or combine the
scripts; the same filename in different phases is allowed.

`hey reload cache` and `hey reload k9s` preserve cleanup failures and report
success only after cleanup succeeds. Dry runs do not invoke cleanup.

`hey pull -o home-manager=github:example/home-manager` accepts hyphenated input
names. `INPUT@REV` resolves the actual locked node, including renamed nodes and
follows, for GitHub/GitLab/SourceHut inputs. Use `INPUT=FLAKE_URI` for other source
types. Only the named inputs are updated; unrelated locked inputs are retained.
Metadata inspection does not write the lock file. Overrides update lock state,
not declarations in `flake.nix`; edit the
declaration as well when permanently changing a dependency's source.

Zsh plugins are loaded from Nix-store packages pinned by the consumer's effective
Nixpkgs inputs. Startup does not clone repositories and `hey reload zsh` does not
update plugin sources. Update the relevant Nixpkgs input and rebuild to update
plugins. Completion caches remain writable under `$XDG_CACHE_HOME/zsh` and are
keyed by the plugin set. See [migration.md](migration.md) for legacy zgenom state.

## AWS and EKS

Enable `modules.shell.awscli2` to generate AWS configuration and the non-secret
`hey/aws.json` capability metadata. EKS tooling and SAML support are independent:
both `eks.enable` and `saml.enable` default to false. AWS-only use adds the AWS
CLI without Nixi's Kubernetes collection or k9s files. To retain that collection:

```nix
modules.shell.awscli2 = {
  enable = true;
  eks.enable = true;
};
```

EKS enablement adds `kubectl`, `k9s`, `kubectx`, `stern` and managed k9s files.
The `eks-bastion` preset defaults it on; an explicit false overrides that preset.
The flag controls this adapter's tooling/files and reported capability, not
authorization to use Kubernetes. Independently declared packages/files remain.
SSO and configured SAML login through `hey eks login` also work with EKS tooling
disabled. Generated configuration changes take effect after a reviewed rebuild.

AWS/SAML typed INI fields reject control characters, and section names reject
whitespace, brackets, quotes and backslashes. `extraConfig` is an explicit
trusted raw-value escape hatch, retaining override precedence and multiline
values (for example nested S3 configuration). It is not sanitized INI or a
place for credentials: generated configuration is stored in the Nix store.
See [migration notes](migration.md) for the name/key restrictions.

`hey eks login [NAME]` accepts a declared SAML account name or an SSO profile
name. SSO uses `aws sso login --profile NAME`; SAML uses `saml2aws login -a NAME`.
Omitting NAME works only when there is exactly one login candidate. Unknown
names fail, and a name shared by SAML and SSO must be renamed in the host
configuration. Rebuild after changing providers so Hey sees the updated
metadata. Profiles backed by static credentials or an arbitrary credential
process are not inferred to be SSO login targets.

SAML accounts can map to a differently named AWS profile through `awsProfile`.
Disabled SAML accounts do not make `saml2aws` a diagnostic dependency.
Login dry runs never open credential files. A failed stored-password login
retries interactively without reusing the failed password.

`hey eks status CLUSTER` and `hey eks doctor [CLUSTER]` inspect existing state;
they do not start/reset VPN services, create kubeconfig directories, or refresh
kubeconfigs, including when routed through a bastion. Missing state makes the
check fail with an explicit setup hint:

- `hey eks vpn start CLUSTER` starts the configured VPN.
- `hey eks kubeconfig CLUSTER` creates or refreshes its kubeconfig.

The existing access workflows (`open`, `use`, `logs`, and port forwarding)
retain their setup behavior. AWS/Kubernetes probes still use the configured
credential provider; provider-managed authentication caches are outside Hey's
control.

The Linux EKS bastion profile can assemble OpenVPN credentials from separate
username/password files. Each must contain exactly one nonempty line, with an
optional LF or CRLF ending; meaningful spaces are preserved. Inputs are
validated before atomically replacing the root-readable runtime credential
file. Keep these as runtime secret paths, not Nix-store credential contents.
The config and all file references are read through protected root-owned paths
and copied to a private runtime snapshot. Scripts, plugins, nested config files
and arbitrary output directives are rejected. The selected user receives no
passwordless service rights unless
`modules.profiles.eks-bastion.openvpn.allowUserServiceControl = true` is explicit.
See [the protected client contract](security.md#protected-openvpn-client).
