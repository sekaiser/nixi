# Core and workflow migration

## Minimal configuration and explicit privileges

Linux Docker no longer adds users to the root-equivalent docker group. Choose
`modules.services.docker.rootless = true`, or explicitly grant administrative
socket access with `grantRootAccess = true`. VM images no longer grant passwordless
activation unless `modules.profiles.vm-image.allowPasswordlessActivation = true`.

`modules.profiles.primary-user.initialHashedPassword` now fails validation when
non-null. Provision a runtime hash file through your secret provider and use
`hashedPasswordFile = "/run/secrets/login-hash"`. That native NixOS option reads
the hash at activation; its lifecycle differs from an initial password. Review
mutableUsers and provider ordering before migrating. Never use a Nix path literal.
Existing hosts are not silently assigned a new password or locked account.

Alacritty preferences moved to `modules.profiles.alacritty-workstation.enable`;
the minimal terminal module only sets terminfo and the selected shell. The bundled
Doom preferences moved to `modules.profiles.doom-workstation.enable`. Custom Doom
directories can still be supplied directly. Existing assets remain preserved.
The preset now also owns the former broad Emacs helper collection, Linux
binutils, symbol font and aliases. Bare Emacs enablement keeps Git, ripgrep and fd;
Tree-sitter grammars, explicit `extraPackages`, optional LaTeX and runtime-state
paths retain their wiring. Enable the preset to retain workstation conveniences,
or declare the subset your configuration needs. Disabling Emacs suppresses the
preset's side effects; it does not delete existing runtime state.
Zsh plugins, prompt, aliases, history policy and utilities now require
`modules.profiles.zsh-workstation.enable`. Tmux bindings, plugins, status tools
and tmuxifier integration require `modules.profiles.tmux-workstation.enable`.
The basic shell modules only wire the selected tools and user configuration.
Mac auto-attach uses both workstation presets plus `modules.shell.tmux.autoAttach`.
The custom desktop-directory layout requires `modules.profiles.home-workstation.enable`.
Existing assets and custom scripts are preserved; explicitly select these presets
to retain the previous behavior. Bare tmux no longer installs a system-wide config.

The same split applies to `modules.profiles.atuin-workstation`, `rust-workstation`,
`go-workstation`, and `vim-workstation` (set `.enable = true`). Bare Rust installs
rustc and Cargo; bare Go installs Go, without a custom GOPATH/GOBIN. Their presets
add the previous development tools and optional Zsh aliases. The legacy `vim`
module still installs Neovim; its preset adds EditorConfig and system-wide `vim`
and `v` aliases. Atuin retains privacy defaults (`auto_sync = false` and
`update_check = false`), with settings now configurable through
`modules.shell.atuin.settings`. Compact UI, Enter/up-arrow behavior and workspace
preferences move to its preset. Zsh integrations only apply when Zsh is enabled.

Java now follows the same split. `modules.dev.java.enable` installs one selected
`modules.dev.java.package`, defaulting to the pinned `pkgs.jdk`. The existing
`openjdk21.enable` and `openjdk25.enable` flags remain compatibility selectors for
that default; an explicit package takes precedence. Choose at most one legacy
selector while Java is enabled. Both module entrypoints share one implementation.

To retain Checkstyle, Gradle, the Java language server, Maven and Java session
variables, enable `modules.profiles.java-workstation.enable`. It defaults the
runtime on and sets `JAVA_HOME`/`JDK_HOME` only for the selected Home Manager user.
Other users and root no longer inherit that user's Java choice globally. Native
user session variables can override these defaults. Java Zsh aliases load only
when Zsh is enabled; disabling the runtime suppresses preset effects too.

```nix
{pkgs, ...}: {
  modules.dev.java = {
    enable = true;
    package = pkgs.openjdk25;
  };
  modules.profiles.java-workstation.enable = true;
}
```

Omit the preset for runtime-only use. Use project development shells for multiple
JDKs rather than merging competing `java` executables into one user profile.
The unused `home.configFile.jdks` scaffold is no longer supplied from the empty
assets directory. Declare any wanted JDK inventory yourself; consumer-owned
inventory declarations remain intact. No installed files are deleted in this
source batch.

Tool presets default their base module to enabled. An explicit base-module
`enable = false` suppresses preset files, packages and hooks as well. Disabling a
module stops managing its configuration; it does not promise to erase every
previously generated file or undo persistent application preferences.

Dependency overrides are now opt-in. Nixi's default packages, checks and dev
shells use upstream pins, and `mkHostFlake` no longer inherits an overlay catalog.
To keep the temporary OpenSSL override, explicitly pass
`overlays.security = inputs.nixi.overlays.security;` to `mkHostFlake`.
Embedded workspaces can instead select `import ./nixi/overlays/security.nix`
in their own overlay definitions. This may trigger large transitive rebuilds.
Consumers already selecting an overlay explicitly retain it until they remove
that selection. Advisory reports and review metadata do not enable overrides.
Choosing upstream defaults is not a claim that the pinned versions are free of
known vulnerabilities; update pins or assess exposure separately. Other OpenSSL
release lines and bundled copies require their own advisory review.

The SSH wrapper no longer enables UseDNS. The native default is compatible with
Hey's connection-policy verifier. Explicit `services.openssh.settings.UseDns = true`
remains supported, but Hey cannot certify DNS-based Match Host policy automatically.

## Pre-publication diagnostics and locking

`hey sync plan` is an explicit build/download preview; ordinary sync behavior
does not change. Evaluation-time builds and lock updates are refused in a plan.
`hey security scan STORE_PATH` requires an explicitly installed advisory scanner.
The optional public dependency-maintenance workflow only proposes updates and
reports findings after repository-owner opt-in. See [dependencies.md](dependencies.md)
for its limited scan scope and temporary override review policy.

`hey project doctor` now exits nonzero when required project tools are absent;
optional tools still warn. CI rejects empty native plans and missing mandatory
security checks. Local sync activation and rollback share the generation-removal
lock, so concurrent Hey mutations wait or time out. External rebuild tools do not
share that lock and must not run concurrently.

These changes alter defaults and activation behavior. Build and inspect your
host configuration before switching; successful evaluation is not a network or
cluster upgrade test.

## Consistent cleanup and diagnostic results

Explicit system `hey profile rm` now refreshes Linux boot entries, like keep-N
pruning and GC. All three deletion paths share the removal helper and lock.
A system keep-N prune also refreshes boot entries when nothing remains to delete,
allowing recovery after a previous boot-refresh failure. User profiles do not
refresh boot entries; no deletion command activates another generation.

SSH/process diagnostics now require the explicit PID, PPID, state, elapsed-time
and command format. Synthetic `HEY_SSH_DOCTOR_PS` fixtures must use that format,
not `ps aux`. Malformed snapshots and failed Zed extension discovery fail the
check instead of claiming healthy state from missing or partial information.

Disabling Home Manager's `programs.gpg.enable` now also disables Nixi's GnuPG
permission hook. It no longer modifies an unmanaged GPG home or fails when that
directory was never created.

Public CI classifies every check using `test_tools/check-policy.json`. New checks
must be explicitly classified; native build-time tests are executed, not merely
evaluated. VM checks still require a separate virtualization-capable runner.

## Diagnostic hardening and neutral agent expectations

Codex plugin and MCP expectations now default to empty lists. Put desired
`modules.agents.codex.plugins` and `mcpServers` explicitly in the consumer;
enabling Codex or Codegraph does not configure their integration automatically.
No mutable agent configuration is removed or rewritten by this change.

EKS doctor now rejects the same oversized or malformed SAML input as login.
Secret doctor withholds raw scanner errors as well as matched values, and
ignores user ripgrep configuration to keep scan scope and formatting predictable.
SSH doctor fails on malformed installed public material and reports complex
client trust settings as unverified; see [the diagnostic scope](ssh.md#diagnostics).

`hey.cache` remains an initialization helper, but no longer reads or writes
executable disk caches. Each invocation runs the supplied generator and only
evaluates successful output in an interactive shell. Existing caches and custom
scripts are left untouched. This makes changed arguments and executable
upgrades effective without manual cache invalidation.

## Consumer-owned policy

Darwin consumers using SOPS with privileged Nixi file copies should opt into
`darwinModules.sops-darwin` instead of the upstream module. This adapts the
RAM-backed provider layout to protected directories and defaults secret/template
paths accordingly. Resolve paths through `config.sops.secrets.NAME.path`;
remove user-home aliases for privileged CA inputs. Nixi's Git and user-certificate
activation now follows providers using `mkAfter`. Old mounts and aliases are
left untouched; see [the macOS migration and identity-path warning](secrets.md#protected-sops-sources-on-macos).

User and host certificate operations now share a bounded validator/installer.
User public keys are read as `targetUser`, including normal user-owned symlinks;
that account must be able to read the key without root's help. CA keys and
pre-signed host certificates require protected runtime sources when invoked as
root. Inputs are limited to 1 MiB, and each certificate operation has a 45-second
deadline. Encrypted/interactive CAs are not supported. RSA, ECDSA and Ed25519
certificates are supported; security-key/FIDO certificate management must remain
external, because the validator cannot preserve that format's semantics.

Pre-signed host certificates now require the matching `publicKeyFile`, a host
certificate with a valid signature/current validity interval, and all configured
principals. Invalid material is rejected before replacing a previous certificate.
Root host-certificate destination ancestors must be root-owned, not group/world
writable, and not symlinks. Neither sources nor existing directories are moved,
chmodded or chowned as a migration step.

Native disablement now also wins over the Caddy, Tang and Tailscale wrappers.
Disabled Tailscale no longer leaves Nixi's IP/autoconnect helpers behind. Caddy
firewall policy uses `services.caddy.openFirewall` and its effective HTTP/HTTPS
ports; upstream opens HTTPS UDP for HTTP/3 as well as TCP. Set that native option
to false to manage firewall rules yourself. Tang's default automatic firewall
rules follow effective numeric `services.tang.listenStream` ports, rather than
always opening 7654. For addressed or Unix sockets, set
`modules.services.tang.openFirewall = false` and supply native firewall policy.

Cilium/Gateway API defaults change from 1.17.2/1.2.0 to 1.19.7/1.4.1, matching
the pinned K3s default's Kubernetes 1.35 version. Do not activate this directly
over a 1.17 cluster: staged minor-version upgrades are required. Read [dependency
maintenance and upgrade guidance](dependencies.md) first. Removed Cilium
NodePort/external-IP enable flags are replaced by the existing kube-proxy
replacement setting; literal L2 interface selection uses the new pattern field.

Native `services.openssh` settings now override Nixi's compatibility defaults
without `mkForce`. Selecting `ports = [2222]` no longer also retains port 22;
check access and firewall policy before switching a remote host. `AllowUsers`,
password authentication, DNS/GSSAPI policy, moduli and trusted-user-CA paths can
be configured natively. Disabling native OpenSSH also disables Nixi's host
certificate renewal units. With no overrides, the existing defaults remain.

Certificate paths are quoted for OpenSSH; managed client trust paths reject
control characters and `${...}` expansion. Privileged Git-secret/user-certificate
copies now verify the source path as well as the destination. Sources under
user-writable directories must move to a protected runtime secret-provider
directory; protected provider symlinks remain supported. A source replaced
during opening fails safely and can be retried. Nothing relocates secrets or
changes filesystem ownership automatically. Old installed Git copies remain
until separately retired. Optional
`modules.shell.git.secretTracking.enable` records private receipts on future
installations, enabling a manual exact-receipt preview/apply workflow. It stays
off by default; existing untracked copies remain subject to private inventory
and separate cleanup review. See [retirement and interruption recovery](secrets.md#retiring-installed-git-secret-copies).

The public Hey package now installs only `hey` and `myip` (an alias for
`hey info -r ip`). Enabling Hey no longer adds the framework source `bin/`
directory to the login shell's PATH. `DOTFILES_BIN` still identifies sources for
completions and nested calls; consumer-owned commands remain available through
their own packages/PATH, `hey exec`, and host/desktop dispatch.

Standalone convenience commands can remain in consumer-owned packages and
directories independently of Hey. Do not delete them merely because no Nix
module references them: interactive use is not visible in that reference graph.
Keep personal bindings pointed at those installed commands. Optional public
utilities require a separate distribution decision, not automatic inclusion in
the core Hey package. No recordings, palettes, credentials, Dock entries or
application bundles are deleted during migration.

`tmuxsel` is now an explicitly approved public utility with its own package;
it is not bundled into Hey. The tmux module installs it by default and exposes
`modules.shell.tmux.sessionSelector` for alternatives. macOS auto-attach uses
that package's executable; a missing selector leaves the shell open. The
selector's existing interactive behavior is preserved.

Zsh no longer shadows the installed `hey` executable with a checkout-path
function. Invoke a development checkout by its explicit `bin/hey` path.
Completion startup checks insecure search paths on every shell, including
cached startup. An unsafe cache is left untouched and completion runs uncached;
correct its ownership/permissions yourself. Fresh caches use a new name.
Legacy compiled startup-file cleanup now runs as the Home Manager user, honors
dry-run mode, and targets only named Nixi startup files. Unrelated `.zwc` files
and private scripts are preserved; no root traversal of the home tree remains.

`macoslinker` was not used by the current modules. Darwin application exposure
remains owned by nix-darwin: the Doom module installs its wrapped Emacs package
in `environment.systemPackages` for `/Applications/Nix Apps`.

Python tests and their CLI runner moved from `tools/` to `test_tools/`. Update
local test commands accordingly, for example `python3 test_tools/test_release.py`
or `python3 test_tools/run_cli_tests.py TEST_NAME`. Runtime helpers and the release
exporter remain in `tools/`; Nix check entrypoints are unchanged.

AWS profile, SSO session and SAML account section names must now be nonempty
and contain no whitespace, control characters, brackets, quotes or backslashes.
Structured INI values reject control characters, including CR/LF and tabs.
Correct malformed typed fields before rebuilding; `extraConfig` is the explicit
trusted raw-value escape hatch for nested/multiline settings, not a secret store.
Its keys accept only letters, digits, underscores and hyphens. Raw overrides
still take precedence, but do not suppress validation of typed fields.

SAML `passwordFileFormat` now defaults to `"password"`: a single password line.
For a combined username/password file, explicitly select `"username-password"`
and leave `usernameFile = null`. Separate username/password files keep working.
Passwords preserve meaningful spaces and accept one LF or CRLF terminator.
Malformed/empty values fail without printing credentials or attempting login.
Old generated metadata without a format field retains the legacy combined-file
interpretation with a migration warning until the next rebuild.

Both homelab K3s profiles expose `agentTokenSecret` and `tailscaleAuthSecret`.
The server additionally exposes `podCIDR`, `serviceCIDR` and `advertisedRoutes`;
its pod CIDR feeds Cilium IPAM as well as K3s. Defaults preserve existing behavior.
Choose these values in consumer policy; no secret files or network state are
migrated by editing these options alone.

The unused `assets/git/credentials-helper.sh` has been removed. No Nixi module
configured it. Consumers referencing this asset directly must select their own
credential helper through native Git/Home Manager configuration. Existing
credential files are untouched; this does not erase previously stored secrets.

EKS metadata now carries schema version 1. Unversioned metadata is still read,
but unknown versions fail. Cluster keys must use letters, digits, underscores
or hyphens; replace path-like keys before rebuilding. Kubeconfig creation now
always uses the same context alias as subsequent commands, including defaults.
Existing kubeconfigs are refreshed by the normal EKS workflow, not activation.

`modules.profiles.secure-ssh.enable` is an optional key/certificate-only Linux
profile. Existing hosts retain their current policy. Test non-root key access
before enabling it; see [security boundaries](security.md).

Profile options are no longer copied wholesale into `hey.info.profiles`. Keep
custom runtime metadata explicit under `hey.info`; never include credentials.
VM-image retention metadata is versioned and only emitted by enabled profiles.
Recognized CLI options now reject missing values before executing any command.
Numeric options are validated even without defaults; forwarded arguments after
`--` remain untouched.
Automatic UTM cleanup now honors the remote opt-out and configured count; an
explicit CLI count cannot enable automatic cleanup. UTM SSH defaults to the
configured Hey user, with `--user` available for hosts using another account.

Darwin's exported packages, checks and dev shells now use `nixpkgs-darwin`, just
like host modules. All these contexts expose the same `pkgs.unstable`, overlays
and Nixpkgs configuration. Expect changed Darwin derivations on the next build.

Disko is available through the explicit Linux import `nixi.nixosModules.disko`.
Existing Linux `target = "qcow-efi"` descriptors retain their Disko import via
a compatibility adapter. Disk layouts and VM-image profiles remain host-owned;
no disks are changed by this refactor.
The `cilium-vm` platform profile also requires this explicit Disko import; it
no longer loads Disko for every Linux host. Existing private Cilium VM hosts
have been updated to retain their disk configuration.

EKS metadata now treats Nix-generated JSON nulls as absent optional values.
Generic AWS enablement no longer opts into EKS tooling. Consumers that want
`kubectl`, `k9s`, `kubectx`, `stern` and the managed k9s files must set
`modules.shell.awscli2.eks.enable = true`. The EKS bastion preset supplies a
default true that explicit false can override. SSO/SAML configuration and login
remain independent; this does not revoke credentials or Kubernetes access.
Preserve wanted workstation tools explicitly before activating this change.
Password-file-only SAML accounts and account-name profile fallback work with
that generated metadata. Routed EKS shells request an SSH terminal. Passwordless
OpenVPN control now requires an explicit
`modules.profiles.eks-bastion.openvpn.allowUserServiceControl = true`.
It grants start/restart/reset-failed only for that service. Updating the local
CLI alone cannot change remote sudo policy.

The homelab SOPS profile now selects its declared identity source explicitly.
If you intentionally combine an age identity file with SSH-derived age or GPG
keys, declare those extra sources through native SOPS options before switching.

- Set `home.stateVersion` to the Home Manager compatibility version already used
  by each host. Do not increase it just because you update Nixi. Keep existing
  `system.stateVersion` values too.
- Set `hey.enable = true` if you want the CLI. The optional
  `modules.profiles.workstation.enable` profile installs the former convenience
  tool collection and defaults Hey on; you can explicitly disable Hey.
- Move your Nix package, caches, trusted/allowed users, build-user IDs and other
  installation policy into consumer modules. `hostModules = [ ./policy.nix ];`
  applies ordinary modules to every host. The core no longer grants the primary
  user daemon trust or selects third-party caches.
- Put unfree-package policy in the composition argument `nixpkgsConfig`, for
  example `nixpkgsConfig.allowUnfree = true`. The default is an empty configuration.
- Linux no longer exports a fabricated `XDG_RUNTIME_DIR`; the login session owns
  that variable. Home Manager remains accessible through its native options.
  Enabling Hey also no longer recursively changes permissions on an assumed
  `~/.config/dotfiles` checkout through systemd-tmpfiles.

The Linux primary-user profile no longer grants supplementary groups, chooses
Zsh, or bypasses shell validation. Use
`modules.profiles.administrator.enable = true` for wheel membership, or set
`modules.profiles.primary-user.extraGroups` explicitly. The Docker service module
still grants its selected user Docker access when enabled. The workstation
profile selects and enables Zsh on Linux; other consumers can set
`modules.profiles.primary-user.shell` and enable the matching shell module.
Review account privileges before switching existing hosts. The private workspace
policy explicitly retains this fleet's former group choices; they are not part
of the published defaults.

Alacritty no longer forces Zsh. Linux omits its shell setting; Darwin explicitly
uses the configured account shell with login arguments. Choose that shell
through the native account configuration (or the Linux primary-user shell
option). Enabled Darwin adapters register the same Alacritty package in the
system application collection as well as the user environment, so managed
Finder discovery does not depend on a previously registered store bundle.
The registration takes effect after reviewed activation; terminal preferences
and Linux package placement are unchanged.

`modules.editors.default` now defaults to `null`, leaving the editor environment
unchanged. An explicit command, such as `"nvim"`, supplies a per-user Home Manager
`EDITOR` default rather than a global export. Native
`home-manager.users.<user>.home.sessionVariables.EDITOR` can override it, and
other users retain their own settings. Install the selected command separately;
for example, enable `modules.editors.vim` when selecting `"nvim"`. Start a new
login session after switching to clear the old global `EDITOR` value.

Tmux and Codegraph resolve their bundled packages through the host's Nixpkgs.
Consumers no longer need to re-export `tmux-status` or `codegraph` as flake
packages just to enable these modules. `hey.packages` remains the consumer's
package namespace; use `modules.agents.codegraph.package` for a Codegraph override.

The unused `modules.xdg.ssh.enable` placeholder and unreachable Rofi runtime
helpers were removed. Remove references to the former; it never configured SSH.

Homebrew is now opt-in and uses native nix-darwin defaults: no automatic update,
upgrade or removal of undeclared packages during activation. Manual Homebrew
commands retain native Homebrew behavior. Existing `modules.desktop.homebrew`
declarations remain aliases, but set `enable = true` explicitly if needed. Nixi
also no longer installs all Nerd Fonts or patches LKL in every package set;
declare fonts and any image-specific overlays in consumer policy.

Dock management is now opt-in: set `modules.desktop.dock.enable = true` to
retain a declared layout. `entries = null` (the default) leaves the layout alone;
an explicit `entries = []` clears it. Entries are translated to native
`system.defaults.dock.persistent-apps` / `persistent-others`; the custom
`dockutil` reset script is gone. Legacy per-entry `options` flags are rejected,
not silently ignored. Use the native options directly for advanced tiles.

Enabling Zed now manages neutral settings, without selecting themes, extensions,
tasks or agent permission modes. Enable `modules.profiles.zed-workstation.enable`
for the former UI, extension and task preset. Agent configuration remains an
explicit host choice, including any `full-access` permission mode. Preset
settings can be overridden individually. The extension drift manifest moves to
`$XDG_DATA_HOME/hey/zed-extensions.json`; Home Manager removes the old managed
manifest on activation, not installed extensions. The doctor uses Zed's native
extension directory on each platform.

Generated Home Manager files no longer force-overwrite existing files. Before
switching, resolve collisions or opt into `home-manager.backupFileExtension`.
An existing backup with the same name can also block activation; inspect it
before moving it. Nixi never automatically removes those backups.

Native Home Manager XDG path overrides now update Nixi's aliases and the selected
user's session variables. These paths are no longer exported system-wide: other
users and root must not inherit the primary user's directories. Home Manager's
XDG integration defaults on; log in again after switching to refresh session
variables. Explicit legacy path definitions retain their priority; conflicting
explicit paths produce a normal option conflict. Home Manager now defaults to
the host package set (`useGlobalPkgs = true`), including overlays and licensing
policy. Remove redundant `home-manager.users.<user>.nixpkgs` settings, move them
to consumer package policy, or explicitly opt into a separate package set.

`home.dir` now defaults to the effective native account home, including overrides
of `users.users.<name>.home`. `home.binDir` forwards to Home Manager's
`xdg.binHome` with the same priority rules as the other XDG aliases. Home Manager
alone exports `XDG_BIN_HOME`; conflicting explicit native/legacy paths remain an
option error. Derived fake/runtime directories follow the effective home.
Codex and OMP state defaults, OMP's config-file diagnostic, and SSH user-key and
certificate defaults now follow `home.dir` too. Explicit module path overrides
remain supported. This changes path selection, not data ownership: existing
agent state and SSH keys are not moved to the new home automatically.

RTK's Codex activation now passes the configured `modules.agents.codex.codexHome`
explicitly, including when activation has no login-shell environment. Both RTK
initializers use Home Manager's dry-run-aware `run` helper. Existing RTK files in
a previously selected directory are not moved or removed.

Generic OMP enablement now leaves mutable settings user-managed and selects no
provider, model, theme, symbol preset or setup version. Existing users who want
the former managed settings must opt into:

```nix
modules.profiles.omp-workstation.enable = true;
```

The preset retains the previous preferences and Codex-dependent provider/model
defaults, without enabling Codex itself. Ordinary OMP settings override its
defaults. Alternatively select `modules.agents.omp.manageConfig = true` and
declare only the fields you want. Optional preference fields now default to
`null`; explicitly requesting `configureCodexModels` also requires a `codexModel`
when Codex is enabled. Explicit `modelRoles.slow` retains precedence.

Managed defaults use Nixpkgs' YAML serializer and a Home Manager activation hook
that merges into private writable user settings. String values retain punctuation
and newlines; each theme field remains independently overridable. No mutable
store-backed config is exposed to OMP. Close OMP during activation, since its
own file lock is independent. Disabling management leaves the existing config,
managed-key sidecar and runtime state untouched; it does not remove old values
or credentials. See [OMP ownership and migration](omp.md) for legacy-link repair
and synchronisation limits.

Darwin Docker no longer forces `DOCKER_HOST` or exports the misspelled
`COLIMAHOME`. Colima keeps its native state discovery, including existing
`~/.colima` installations, and Docker uses its selected context. After switching,
start a fresh shell (or unset the old `DOCKER_HOST` and `COLIMAHOME` variables).
Use `docker context ls` to inspect contexts and select the intended one explicitly.
For a custom state directory, set `modules.services.docker.colimaHome` to an
absolute path; Home Manager creates it and exports `COLIMA_HOME`. Selecting a new
directory does not migrate old VM state. Plan that migration separately; Nixi
never moves/deletes VMs or switches contexts during activation. Remove the unused
`modules.services.docker.cacheTTL` option if previously configured.

The unused `modules.theme.fonts.{mono,sans,terminal,icons}.package` and
`modules.theme.fonts.packages` options were removed. They never installed fonts;
use native `fonts.packages` for installation. Theme font names/sizes remain
available as metadata.

Zsh's derived paths are now resolved in the managed user's session variables,
on both platforms. They are no longer expanded before XDG initialization or
exported into other users' shells. Start a fresh login session after switching.

`env` now exports literal values, validates variable names, and joins list values
with colons. `$HOME`, `$XDG_CONFIG_HOME`, command substitutions and quotes are
preserved, not evaluated. Resolve paths in Nix, preferably through the selected
user's native Home Manager settings, or use `environment.extraInit` for intentional
shell code. The Go, AWS, Docker and tmux modules have been migrated. Tmuxifier's
bin directory uses `home.sessionPath` instead of replacing `PATH`.

GnuPG now uses Home Manager's `programs.gpg` and `services.gpg-agent`, including
its per-user systemd/launchd service. Disable the old system-level
`programs.gnupg.agent.enable` if explicitly configured. The default homedir remains
the user's XDG config directory plus `/gnupg`; existing keys are not moved or
rewritten. Native HM homedir and agent settings can override the defaults.
Nix supplies `pinentry_mac` on Darwin and `pinentry-curses` on Linux; customize
`modules.shell.gnupg.pinentryPackage` or native `services.gpg-agent.pinentry.package`.
Directory initialization runs as the HM user, sets only the homedir to mode 0700,
and rejects a symlinked homedir rather than recursively changing permissions.
For an intentional symlink, explicitly configure its real destination as the
homedir. Start a fresh login session after switching to hand off the agent.

Unused library exports `mkWrapper`, `mkLauncherEntry`, `toPrettyJSON` and
`compileSCSS` were removed. Use native `pkgs.symlinkJoin`/`pkgs.makeWrapper`,
`pkgs.makeDesktopItem`, `builtins.toJSON` or `(pkgs.formats.json {}).generate`, and
a build-time Sass derivation respectively. Keep generated JSON/CSS as file paths
when possible instead of reading build outputs during evaluation.

The Git module now uses Home Manager's native Git module. Its legacy sections
render before native `programs.git.settings`, which can override them. Ordered
legacy entries and profile snippets remain supported; native ignores and
attributes merge with the module's defaults.
Git no longer requires the Nixi Zsh module. Its Zsh aliases are added only when
that module is enabled; configuration and tools work independently with other
login shells.

Git profile-parent migration now respects Home Manager dry runs and runs after
`writeBoundary`, before new links are installed. It only removes parent symlinks
that match Home Manager's ownership pattern, leaving real directories and other
symlinks alone. Native collision checks still run first: changed files beneath a
legacy directory link can require manual conflict resolution before migration.
Inspect and preserve that old configuration before retrying; Nixi no longer
removes the parent link to bypass those checks.

Platform-restricted package/check recipes must use the explicit `systems` /
`package` wrapper described in [the composition API](flake-api.md). Nixi no
longer evaluates every derivation's `meta.platforms` just to enumerate outputs.

`nixi.lib.mergeChecks` rejects duplicate check names within a system. Rename or
namespace overlapping checks before combining outputs; derivations are no longer
recursively merged. The general `mergeAttrs'` helper uses rightmost-wins leaf
values, concatenates lists, and treats derivations as atomic values.

## K3s and network policy

Tailscale authentication now uses NixOS' `tailscaled-autoconnect.service`, not
Nixi's former `tailscale-autoconnect.service`. Update any custom unit dependencies
that referenced the old name. Authentication retains the native notify/readiness
protocol and retries failed starts with a bounded startup timeout. The existing
`tailscale-fetch-ip.service` still produces `/var/tailscale/ip` for homelab K3s;
it now waits for a nonempty address and replaces the file atomically.
With manual authentication, this helper is only started when explicitly requested
or required by a dependent unit, so it does not hold up boot waiting for login.

`modules.services.tailscale.keyFile` is loaded as a runtime systemd credential,
so spaces and shell punctuation in its path never enter the authentication
script. No key contents are copied into the Nix store. Leave it `null` for manual
login or configure native `services.tailscale.authKeyFile` directly; an explicit
native path overrides the credential bridge. Native package, port, certificate
permissions and routing settings remain available. Secret-provider ordering is
still the consumer's responsibility; missing credentials fail and retry rather
than being treated as successful authentication. Check a Linux boot before
rolling this service-name change out over a Tailscale-only connection.

The generic Caddy module no longer disables automatic certificate management or
creates a Gitea proxy. The generic Gitea module no longer assumes a loopback
backend on port 3301, an HTTPS public URL on port 8890, or secure cookies behind
that proxy. For the former integration, explicitly select:

```nix
modules.profiles.gitea-tailscale = {
  enable = true;
  exposure = "tailnet";
  listenAddresses = [ "100.100.100.10" "fd7a:115c:a1e0::10" ];
};
modules.services.gitea.domain = "git.example.ts.net";
modules.services.tailscale.keyFile = "/run/secrets/tailscale-auth-key";
```

This profile defaults the three services on, retains the loopback backend and
port 8890, and grants Caddy's effective user permission to obtain Tailscale
certificates. Replace the synthetic listen addresses with this host's assigned
Tailscale addresses. The default tailnet mode requires explicit bindings,
a loopback backend and no global grant for the HTTPS port. `httpsPort` changes
that port. Select `exposure = "public"` explicitly for a public deployment;
certificate selection alone does not provide tailnet isolation.
Tailscale must be authenticated, the configured domain must be supported by its
certificate provider, and HTTPS must be enabled in the tailnet. Certificate
management is [site-scoped](https://caddyserver.com/docs/caddyfile/directives/tls),
so unrelated public Caddy sites keep normal certificate automation. Existing
Gitea data is not moved. Review the complete Caddy configuration and test IPv4
and IPv6 access from tailnet and non-tailnet peers before rollout. See
[the exposure contract](security.md#gitea-exposure).

The generic K3s server now writes its administrative kubeconfig with mode `0600`.
It no longer exports that privileged credential to every user's environment.
Use `sudo k3s kubectl` for local administration, or provision separate RBAC-scoped
credentials for users. Check and revoke any previously copied admin credentials
according to your cluster's access policy; changing permissions is not revocation.

K3s, Tailscale, Caddy, Gitea and VM profiles no longer turn the firewall off.
Caddy now leaves `services.caddy.openFirewall = false`; explicitly enable it for
public Caddy deployments or declare narrower firewall rules. The Gitea profile
grants only its selected interface/global port according to exposure mode.
Tailscale opens its UDP port.
Homelab profiles explicitly trust the Tailscale/Cilium interfaces they use.
For other topologies, declare the required API, cluster and overlay access in
your own policy. Test reachability before replacing an existing deployment.

Plain `modules.services.k3s-server` / `k3s-agent` no longer imply Tailscale,
Cilium, Gateway API or Flux. For the former server recipe, explicitly enable:

```nix
modules.profiles.k3s-cilium = {
  enable = true;
  apiHost = "control-plane.example.invalid"; # your reachable API endpoint
  flux.enable = true; # optional
};
```

The homelab server profile already composes this recipe. Cilium and Gateway API
are fetched with content hashes. The current pair
and cluster-upgrade requirements are documented in [dependencies.md](dependencies.md).
The chart is normalized to a deterministic gzip archive during the build. Flux
manifests are rendered by the Flux CLI in your locked Nixpkgs, including its
network policies; they are no longer downloaded from an unversioned `latest`
URL. This pins bootstrap inputs, not every image by digest or later GitOps state.

K3s' native `autoDeployCharts` and `manifests` options now reconcile these addons.
Before migrating an existing cluster, inspect its Helm release ownership,
installed Cilium/Gateway/Flux versions, CRDs, network policies and Flux-managed
objects. The previous unpinned Flux bootstrap may have installed another version.
Resolve ownership/version conflicts before switching; do not assume this is a
zero-downtime migration. Disabling a manifest or profile does not necessarily
uninstall cluster resources. Any old unmanaged `/usr/bin/cilium` file is left
untouched; remove it separately only after verifying what owns and uses it.

## CLI behavior

`hey gc -d` prunes only the selected profile: the current user's Hey profile by
default, the system profile with `--system`, or both with `--all`. Collection of
unreachable store paths is still store-wide. Profile pruning and Linux boot
entry refresh happen before collection; a failure stops the command. Preview
the exact paths and commands with `hey -! gc --system -d`.

`hey.enable` now installs only the core runtime. For the former tool collection,
enable `hey.development.enable` and `hey.diagnostics.enable`, or use the
workstation profile, which defaults both on. Add individual tools with
`hey.extraPackages` if you do not need a complete group.

`hey check all` now validates only the selected consumer's checks and hosts.
Framework maintainers should separately run `hey check framework`, `unit`, `cli`
and, on macOS, `utm-cli`. Consumers do not need to re-export Nixi's modules or
internal check suite.

`hey profile rm` preserves multi-digit negative generation operands and resolves
the entire removal plan against one snapshot. Invalid or current-generation
operands reject the whole operation. `hey project clean --yes` now uses a single
Git force flag, preserving nested repositories and worktrees even inside ignored
build directories. The outer repository's tracked files remain protected too.

System rollback now activates and verifies the selected generation. This can
restart services; use dry-run mode first. Unsupported project checks/tests now
exit unsuccessfully instead of treating `git status` as validation. See
[Hey workflows](hey.md) for recipe precedence and platform-specific behavior.

Locks are acquired atomically and released at scope exit, including errors.
Dry runs do not create locks. A held or stale lock fails after a bounded wait
(30 seconds by default); confirm no owning process remains before manually
removing a stale lock. A process killed with SIGKILL cannot run cleanup.

`hey utm update` supports only `--mode switch`. Other modes are rejected before
building or contacting the VM; they no longer accidentally persist test changes.
UTM commands never reset SSH host trust. Confirm a new VM's fingerprint with
`hey utm ssh VM` before running non-interactive checks or updates. See
[the UTM guide](utm.md) for verified key-rotation recovery.

## Secret and certificate installation

Git secrets and SSH user certificates now use a shared installer that drops to
the recipient before traversing destination directories. Existing directories
must be writable by that user; activation no longer repairs their ownership as
root. Inspect and correct ownership deliberately if migration reports a failure.

Linux host certificates now use `nixi-ssh-host-certificates.service`, ordered
after SSH host-key generation and before sshd. Missing configured inputs fail
the service rather than silently skipping initialization. A daily timer refreshes
certificates and reloads an active sshd. SOPS's installation service is detected
automatically when present; other service-based secret providers must be listed
in `modules.services.ssh.hostCertificateDependencies`. See [SSH](ssh.md) for
renewal and pre-signed certificate requirements.

Socket-activated OpenSSH is also supported: certificate installation is required
before `sshd.socket` starts accepting connections. Its default early-boot socket
ordering is disabled to avoid a cycle through the secret provider's service;
shutdown ordering is retained. Per-connection daemons read renewed certificates
directly, so that mode does not reload `sshd.service`.

## Retired automatic cleanup and mutable dotfile swaps

`hey ssh kill-stale` now fails with a migration message and never probes or
terminates processes. Forwarding, multiplexing, and a detached parent do not
establish that an SSH connection is stale. Use `hey ssh ps` or `hey ssh doctor`
to inspect connections, then explicitly terminate only PIDs you have reviewed.

`hey swap` is now read-only. `hey swap --list` (also `-l`, or no arguments)
retains the legacy inventory, including saved links whose store target no
longer exists. `sync` continues to warn about outstanding swaps. Attempts to
swap, unswap, reset, or force an overwrite fail without changing files.
Neither activation nor this migration deletes editable copies or saved links.

For each existing swap:

1. Use `hey swap --list` and inspect `FILE` and `FILE.swapped` individually.
   The saved link should point to the intended Nix-store file.
2. Preserve the editable `FILE` at a new, non-existing backup path. Move any
   desired changes into your declarative configuration before rebuilding.
3. With `FILE` now absent, restore the saved link by moving `FILE.swapped` to
   `FILE`. Do not overwrite the editable file directly. If the saved link is
   dangling, keep the backup and recover the file through Home Manager instead.

Successfully restored entries disappear from the inventory automatically;
there is no need to delete the legacy registry to run `sync`.

## Variable storage and discovery

`hey vars` keys are single names, not paths. Empty names, `.`, `..`, separators,
NUL bytes, and multi-segment runtime keys are rejected before accessing state.
Use separate `vars/new` stores to group runtime variables. Reads refuse
non-regular files; replacing a value atomically replaces a destination symlink
without touching its referent. New state is private (directories 0700, files
0600), and dry-run set/delete/clear operations do not write state.

Recursive module discovery preserves relative imports into the enclosing
source tree. `mapModulesRec` and `mapModulesRec'` also reject a `group.nix` file
alongside a recursive `group/` directory; rename one side instead of relying
on the old silently discarded subtree. Host discovery still flattens grouping
directories and rejects duplicate final host names.

The CLI fixture suites now live under `test/cli/` and are loaded only by the
corresponding `hey check unit`, `cli`, or `utm-cli` command. These command names
are unchanged; their dry-run variants only report the selected suite.

## Evaluated diagnostics and pinned shell plugins

`hey host explain` now reports evaluated configuration instead of re-importing a
presumed host file. The obsolete `host file:` line is removed. `hey host doctor`
checks metadata evaluation by default; pass `--storage` to retain the former
opinionated storage checks. Evaluation errors are no longer reported as empty
or unknown metadata.

Zsh no longer bootstraps or updates zgenom. Nix supplies fzf integration,
vi-mode, fast-syntax-highlighting, completions, autosuggestions, history search,
Powerlevel10k, and autopair. History search uses Nixpkgs' upstream zsh-users
package instead of the dxrcy fork; fuzzy and prefix search settings remain.
`ZGEN_DIR` is no longer exported. Existing zgenom clones are left untouched;
neither activation nor reload deletes them. Move any local plugin modifications
into Nix overrides before choosing to remove those checkouts yourself.

Reload hooks now fail fast, and reload no longer reports success after a failed
hook. Generated scripts enable `errexit` and `pipe_fail`; guard deliberately
optional commands with `|| true`. Failed and forced-failed attempts remain
retryable, while successful duplicate events are suppressed under the lock.
Hook names that normalize to the same filename, such as `task` and `50-task` in
one phase, now fail evaluation instead of silently dropping a script. Rename one
with a distinct priority/name, or explicitly combine the commands.

Structured SSH calls preserve argument boundaries. For example, an EKS log
filter `api|worker` reaches the remote tool as a literal filter, not a pipeline.
With `hey utm ssh`, pass shell syntax explicitly through `sh -c`, for example:

```sh
hey utm ssh VM -- sh -c 'uname -a | cut -d " " -f 1'
```

`hey build iso` writes `result-iso` rather than changing the system profile.
`hey build` and `hey build -a` resolve packages from the running framework,
not from the consumer flake. They now leave result links in the caller's working
directory, with the dependency package using `result-hey-janet-deps` so it does
not replace the Hey `result` link.

`hey project` recognizes `.envrc`, `gradlew`, and process-compose definitions as
project roots. It searches ancestors outside Git as well; within Git, it never
crosses the repository boundary. Cleanup still refuses to proceed without
successful Git safety checks. Project and developer watch commands now preserve
literal argument boundaries through Watchexec, just like `hey watch`.

The undocumented `hey profile -r` flag has been removed. It had no effect:
profile commands already read the current generation state on every invocation.

Explicit `mkHostFlake` dependency overrides now reach module discovery on both
platforms and are no longer exposed as raw flake outputs.

## Docker pruning and Gitea deployment defaults

Enabling `modules.services.docker` on Linux no longer schedules automatic
pruning. To deliberately retain that destructive maintenance policy, opt in
through native NixOS options in your private consumer:

```nix
virtualisation.docker.autoPrune = {
  enable = true;
  dates = "weekly";
};
```

Review the native pruning flags and retained data before enabling it. The prune
unit can start Docker to perform its work even when `enableOnBoot` is false.
No existing containers or images are deleted by this configuration change.

The Gitea adapter now wires only enablement, domain, display name and log level.
Existing direct adapter users must select the compatibility preset to retain
their deployment defaults:

```nix
modules.profiles.gitea-compatibility.enable = true;
modules.services.gitea.domain = "git.example.test";
```

This preset retains `/data/apps/gitea`, SQLite, LFS, dump, mail, SSH and login
defaults at `mkDefault` priority. Ordinary `services.gitea` settings still override
them without `mkForce`. The Gitea/Tailscale preset selects compatibility by
default, preserving its previous deployment policy.

To deliberately use native deployment defaults through the adapter:

```nix
modules.services.gitea = {
  enable = true;
  domain = "git.example.test";
  deploymentPolicy = "native";
};
modules.profiles.gitea-compatibility.enable = false;
```

An active adapter requires exactly one policy choice. Missing or ambiguous
choices fail an assertion before activation, preventing a silent switch to
native storage defaults. Disabling the adapter or the native service suppresses
the compatibility policy. New deployments may configure `services.gitea`
directly and omit both the adapter and preset.

The native selector performs no data migration. Review storage, database, mail
and authentication settings before selecting it. Changing `stateDir` or database
settings requires a separately planned backup and migration; this refactoring
does not move repositories or convert data.

## Reconciled security hardening

`hey sync` now builds as the normal user before requesting sudo for fixed-output
activation. Do not run the whole command with sudo or copy personal Git/SSH
credentials into root's home. The privileged helper receives candidate and
selected/running checkpoint store paths with a clean environment. Custom
activation hooks must embed needed paths in their configuration; they no longer
inherit caller `DOTFILES`, `DOTFILES_HOME`, `NIX_CONFIG` or SSH agent state.
User build/activation failures preserve their exit status and release the caller
lock/temporary roots. The helper attempts guarded output recovery after activation
failure, but cannot restore arbitrary writable application or Homebrew state.

Local default-system profiles with modern activation layouts are supported.
Remote deployment, custom profiles, specialisations, bootstrap and legacy
`activate-user` require a separately reviewed native procedure. Supported action
and build-option details are in [Hey workflows](hey.md#local-sync-builds-and-activation).
`--fast` remains a compatibility flag; direct builds never re-execute a rebuild
frontend. Linux VM builds can use configured cross/remote builders without
granting activation privileges. No passwordless activation rule was added.
Native root/VM and actual private-input checks remain rollout gates; the old
one-time migration procedure and its protected recovery material remain intact.

Linux Docker and K3s adapters now default their native enable flags, so ordinary
`virtualisation.docker.enable = false`,
`virtualisation.docker.rootless.enable = false` and
`services.k3s.enable = false` take effect without `mkForce`. Docker client tools,
aliases and client state paths remain available for remote Docker use. A disabled
root daemon receives no adapter-granted docker group membership; explicit user
groups remain unchanged. A disabled K3s service receives no agent helper package
or Cilium recipe manifests, CLI or firewall trust. The selected K3s adapter still
requires its corresponding role when the native service is enabled. Adapter
enable switches express requested configuration, not observed daemon state.
Homelab presets also suppress K3s unit dependencies and Cilium interface trust
when K3s is disabled; their explicitly enabled Tailscale policy remains in force.

The Cilium recipe now shares one API port and IPv4 pod CIDR with K3s:

```nix
modules.services.k3s-server.enable = true;
modules.profiles.k3s-cilium = {
  enable = true;
  apiHost = "control-plane.example.invalid";
  apiPort = 7443;
  podCIDRs = ["192.0.2.0/24"]; # documentation-only example; choose your network
};
```

Set those profile options instead of adding native `--https-listen-port` or
`--cluster-cidr` flags. Managed network flags must appear exactly once as
canonical list entries; duplicate, split, conflicting or missing flags fail
evaluation. The generated HelmChart must retain matching API/IPAM settings,
IPv4 cluster-pool mode and kube-proxy replacement. Whole native values overrides
remain possible when these invariants hold; incompatible or opaque values fail.
This recipe supports one IPv4 pool. Compose native services directly for other
topologies. Homelab `podCIDR` continues to feed the same shared settings.

This establishes source consistency, not a live network guarantee. Runtime K3s
configuration/environment files, systemd command overrides, all cluster servers
and actual reachability still need review. K3s documents
[cluster-wide critical settings](https://docs.k3s.io/cli/server#critical-configuration-values),
including the pod CIDR and CNI flags. Changing an existing cluster's pod network
requires a separate migration plan; these source changes do not migrate it.
Disposable Linux boot/network tests remain a release gate.

SSH certificate signing now passes an anonymous CA snapshot descriptor to
`ssh-keygen`, replacing the named `ca` staging copy. Linux uses sealed memory;
Darwin uses an immediately unlinked temporary file. Configured source paths,
certificate validation, privileges and deadlines retain their existing contract.
Darwin storage may retain bytes and surviving processes may retain descriptors
after an uncatchable kill. Old staging directories and provider keys are left
intact; cleanup and rotation require their own review. See [SSH lifecycle](ssh.md).

The Darwin Hey adapter no longer sources the installer-owned `nix-daemon.sh`
after nix-darwin's environment setup. That extra bootstrap could put an old
installer-profile client ahead of the configured system client in every fresh
zsh. Native nix-darwin initialization remains responsible for Nix setup and
profile ordering; Hey still adds its own launcher/completions. This change does
not uninstall an installer profile, alter daemon state or modify stored
generations. After normal reviewed activation, verify fresh login, interactive,
tmux and development-shell client selection with `hey doctor nix --verbose`.
The diagnostic reports the original caller PATH client, Hey's client and the
connected daemon separately; mismatches warn, incomplete probes fail.

OpenVPN's EKS bastion adapter now stages a protected runtime snapshot before
starting. Move its client config, private keys and credentials into root-owned,
root-private files under protected root-owned directories; public certificate
files may be readable by others but must not be writable by them. Supported
provider symlinks must also resolve through protected directories. ACLs must not
grant untrusted writes. Relative references, includes, scripts, plugins,
management interfaces and arbitrary output-file directives are rejected.
Review the [supported subset](../tools/openvpn_client.py) before switching;
advanced configurations need a separately reviewed native OpenVPN service.
Native up/down/resolver hooks and native inline authUserPass are incompatible.
Declare either a combined two-line authFile or both split credential paths.
The helper preserves meaningful credential spaces and copies referenced inputs
into the root-private runtime directory. Linux VM/boot acceptance is still
required; do not deploy the change over a sole remote access path without it.

`CODEX_HOME` now belongs to the selected user's Home Manager session variables.
Start a fresh login session after activation. Existing Codex state is not moved.
Verify GUI launches separately when using a custom home, because desktop apps
may not inherit shell session variables.

Inline SAML usernames become Nix store contents even when supplied through
private source. For sensitive values, leave `username = null` and configure
`usernameFile` through a runtime secret provider. This source change does not
remove historical store files or revoke previously exposed credentials.

`hey doctor secrets --strict` provides a local marker gate: 0 clean, 1 findings,
2 incomplete/failed scan. Warning-only mode remains the default. This scan does
not replace review and independent scanning of the exact publication export.
