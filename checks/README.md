# Flake Checks

This directory contains Nix flake checks. Janet unit tests live under
`test/hey` and are run through `hey check unit`.

Current checks:

- `ci-check-plan` verifies that every check is explicitly classified in
  `test_tools/check-policy.json`, with no missing, stale or duplicate entries.
  Public CI builds all available `native` checks. `evaluation` is reserved for
  checks whose assertions run during evaluation and whose builders only touch
  their output; `vm` requires separate virtualization-capable runners. Review
  the classification whenever adding runtime assertions to an existing check.
- `publication-boundary` checks the reviewed release manifest and exercises the
  exporter against history, unreviewed files, symlinks and changed-content cases.
- `tang-policy-boundary` verifies that Tang requires a consumer-supplied network
  allowlist and retains the upstream deny-by-default socket policy.
- `module-layout` enforces repository layout conventions for modules, overlays,
  and test directories.
- `workspace-layout` enforces the no-bridge workspace root: framework paths
  stay under `nixi/`, host inventory stays under `hosts/`, and root-level
  symlink or mirror aliases are rejected.
- `home-file-ownership` rejects framework declarations that force-overwrite
  existing Home Manager files.
- `home-manager-integration` checks native/legacy XDG path agreement, shared
  consumer package policy, user-isolated session variables, a small Hey runtime,
  safe Homebrew aliases and native/legacy Git merging.
  It covers native account-home relocation, native/legacy binary directories,
  and default/forced alias priorities on Linux and Darwin.
  Agent and SSH defaults must follow relocated homes while explicit paths stay
  authoritative. Generated Git migration is tested with dry runs, the pinned
  Home Manager collision checker, repeated execution and user-owned paths.
- `dependency-overrides` verifies direct-over-input precedence and effective
  dependency context on both Linux and Darwin, including Home Manager imports
  and exclusion of adapter arguments from public outputs.
- `package-context` compares host and exported package/check/shell recipes on
  all supported systems, using distinct stable, Darwin and unstable sources,
  ordered overlays and explicit dependency overrides.
- `emacs-policy` evaluates the real Linux/Darwin module graph with a synthetic
  Doom constructor, avoiding IFD and foreign Emacs builds. Both Linux
  architectures and Darwin cover minimal/preset package sets, retained helper
  priorities and wrapper ordering, disable behavior, fonts/aliases, custom package
  and runtime paths, optional LaTeX, macOS bundle registration and the Tree-sitter
  callback. This checks wiring; actual Emacs builds, grammar loading and GUI
  acceptance remain separate. CI evaluates it through `flake check --no-build`.
  The source contract checks the release URL/hash, Cocoa/PGTK, native compilation
  and Tree-sitter, and compares every builder attribute except source with
  Nixpkgs' release mode. Negative controls reject Git source, lost patches,
  added autoreconf and missing GUI flags. This does not test patch application.
  The separate opt-in `security/review-emacs-patches.py` qualifies archive patch
  application and runs `test_tools/probe_emacs_source.el` in an existing 31.1
  interpreter. Its explicit supplemental username correction passes 17/17 while
  retaining the failing baseline/upstream controls. This review probe is not a
  native corrected Emacs/Doom build or a default passing CI gate.
- `dependency-coverage` classifies every public package definition, forces all
  representative public scan derivations on three systems without realizing
  outputs, and verifies the source-bound inventory and documented exclusions.
  Native synthetic scanner tests exercise findings/no-match/incomplete protocols,
  public-only staging, root selection, npm auth/config isolation, lock retention,
  identifier normalization and bounded command capture. The runtime-input suite
  also checks opt-in/read-only workflow policy and the three-platform scan matrix.
  These checks do not contact advisory feeds or resolve excluded Doom/image graphs.
- `agent-memory` checks service wiring and offline adapter contracts. Its opt-in
  real Core test uses synthetic state and an ephemeral loopback listener outside
  the Darwin build sandbox. `test_tools/probe_memory_http.mjs` is a separate
  opt-in data-URL integrity probe for built Core packages; it reports each npm
  resolution context and Node's bundled fetch separately. These bounded tests
  do not establish every advisory's reachability or consumer acceptance.
  `--require-bundled` requires both to pass; the replacement Node 24 pin proposal
  adds this strict probe to mandatory native CI. It is not active on the working
  pins. With `NIXI_MEMORY_CORE` and its `NIXI_MEMORY_NODE` supplied, the external
  test suite also runs the strict probe and real Core round trip (14 tests).
- `disko-opt-in` checks explicit Disko imports, absent providers, legacy
  `qcow-efi` descriptors and Cilium VM disk-layout compatibility. Ordinary Linux
  hosts must not load Disko; Darwin rejects the legacy image target.
- `user-file-installation` tests privilege-drop ordering, atomic file replacement
  and destination-symlink handling without root or real secrets. It preserves
  existing directory permissions, rejects writable/symlink parents, and checks
  pinned-directory replacement and temporary-name collisions.
  Source checks cover protected provider symlinks, ownership/modes, special-file
  refusal and concurrent replacement. Privileged traversal is exercised with
  simulated ownership and a synthetic root, never actual root access.
  Three-target Git policy fixtures check default-off receipt tracking, selected
  recipient paths, overlap rejection and the absence of automatic retirement.
  Tracked-copy tests exercise private receipts and the packaged manual CLI,
  read-only previews, explicit/stale tokens, unchanged identity/content, unsafe
  ownership/mode/link refusal, locking and recoverable capture/interruption
  handling. Only disposable synthetic files are retired. A test-only strict-
  ancestor model supports in-process Linux namespace fixtures; actual CLI
  subprocesses retain all production guards. Four positive CLI cases explicitly
  skip under an unmapped sandbox root, where real refusal is tested instead.
  `openvpn-client-boot` supplies real-root guest positives. Darwin and ARM Linux
  native suites pass; actual provider/ACL and consumer recovery remain separate.
- `ssh-certificate-tool` executes the packaged certificate helper with synthetic
  keys. Tests cover user/host signing, pre-signed input, validation before atomic
  replacement, FIFO/symlink/oversize refusal, encrypted CAs, Python environment
  isolation, and signing timeout cleanup. Signature corruption, key/type/time/
  principal mismatches and privilege-drop ordering are checked directly too.
  No root credentials or live services are used by these native build tests.
- `service-overrides` applies a shared native disable/firewall-opt-out matrix to
  OpenSSH, Caddy, Tang and Tailscale, plus native Docker/rootless and K3s disables.
  Disabled daemons remove adapter grants, helper packages/units and Cilium
  manifests/firewall trust; Docker client tools and explicit user groups remain.
  Capability metadata must not acquire service entries from disabled adapters.
  Effective port changes must not retain old openings; disabled services must
  not leave Nixi helper units behind. Addressed
  Tang sockets use explicit consumer firewall policy.
- `system-activation` is a required native security check. It exercises fixed
  local output selection, clean privileged environments, stale checkpoints,
  protected executables/metadata, lock contention, failure recovery and handled
  termination using temporary fake profiles. Focused CLI cases mock sudo and
  prove caller credentials reach only user builds, malformed outputs cannot
  reach activation, build failures preserve status and temporary roots/locks
  are released. A real isolated Nix preview refuses evaluation-time builds.
  No live profile, root activation, service or bootloader is exercised.
- `ssh-certificate-lifecycle` checks host-key/secret ordering, required startup,
  both daemon and socket startup, periodic renewal/reload and privilege-dropping
  user-file installation. It also evaluates opt-in user-certificate timers on
  Linux and launchd scheduling on macOS, and executes native generated scripts
  with missing synthetic keys to test required versus best-effort signing.
  It rejects invalid Git secret paths and conflicting destinations, and performs
  synthetic user-certificate issuance and renewal with the real signing tools
  and installer, including preservation of the previous certificate on failure.
  Native OpenSSH parsers check generated paths with spaces, quotes and percent
  characters; certificate labels are tested as literal shell data.
- `ssh-certificate-boot` runs the actual host-certificate units with daemon/socket
  SSH startup, renewal, missing-CA preservation and blocked-CA dependency cases.
  Root-assisted recipient signing rejects a root-only symlink and FIFO promptly.
  Its three guests use synthetic keys. Hardware acceleration remains the default;
  software emulation is an explicit review option with a bounded global timeout.
  Evaluating the derivation alone is not a boot test.
- `openvpn-client-boot` runs production preparation under real Linux root/systemd,
  checking provider generations, private snapshots, exact recipient sudo grants,
  unsafe hooks, ownership/ancestor links, FIFO bounds and clean recovery. It also
  exercises packaged tracked installation/recipient retirement, OMP helper updates
  and the exact generated Home Manager hook. Its observer makes no VPN connection.
  Default checks require a hardware-capable test runner; explicit bounded TCG
  reproductions use `allowSoftwareEmulation = true`. See the dated boot evidence.
- `system-activation-boot` exercises the packaged activation helper as real root
  inside a disposable Linux guest. It covers dry/test activation, real refusal
  boundaries, distinct-system switch/return and recovery after the alternate
  genuine activator fails after changing configuration and checkpoints. Both
  closures and generations remain retained. The guest uses direct kernel boot
  with GRUB disabled; physical bootloader/reboot behavior is outside this scope.
  Default checks retain hardware acceleration requirements; software emulation
  requires explicit opt-in. VM checks are classified separately: the native public
  workflow evaluates them but does not execute them automatically.
- `shell-environment` runs generated Linux/Darwin shell initialization in clean
  environments for two users, checking custom XDG paths, literal exports, variable
  name validation, PATH preservation and user isolation for Go/AWS/Docker/tmux.
  Editor selection covers unset, explicit and native-overridden settings without
  leaking the primary user's choice into another user's session.
  The packaged executable set is exactly `hey` and `myip`; wrapper argument
  forwarding and removal of the raw source-bin PATH entry are also checked.
- `eks-integration` checks Linux/Darwin AWS authentication metadata and runs the
  generated OpenVPN credential preparation against dummy files. It covers path
  quoting, missing final newlines, validation, atomic replacement and permissions.
  Its package/file matrix covers AWS-only, SAML-only, EKS opt-in/disable and
  consumer-owned overrides on x86_64 Linux, ARM Linux and Darwin configurations;
  Linux bastion fixtures retain EKS by default and accept an explicit opt-out.
  Four serial CLI regressions cover generated authentication metadata, login
  provider selection with EKS disabled, diagnostics and invalid optional values.
  It rejects structured INI injection and malformed names/keys, parses generated
  settings with the AWS CLI without authenticating, and checks raw overrides,
  nested S3 values and SAML scalar serialization.
  Its generated authentication metadata and exact service-scoped sudo rules
  also feed the real CLI tests, including nullable SAML fields and VPN restart.
- `gnupg` checks platform-specific Nix pinentry, native HM overrides, per-user
  service environments, and executes directory initialization against disposable
  fixtures, including existing permissions and symlink refusal.
- `java-policy` evaluates runtime-only, legacy and custom package selection,
  workstation tools, disabled presets, Zsh gating and consumer overrides on both
  Linux architectures and Darwin. Native JDK 21/25 and workstation profiles use
  collision-rejecting package unions; a bounded compiler/runtime probe verifies
  the selected executables. `shell-environment` separately executes generated
  selected-user, other-user and root environments to check Java variable scope.
  No real consumer project, global shell or installed profile is changed.
- `user-policy` verifies neutral Linux account defaults, explicit administrator
  and workstation profiles, service-scoped Docker access and removed helper exports.
  Docker enablement must not schedule pruning or open TCP ports; native pruning
  opt-in/opt-out and schedule/flag overrides are checked explicitly.
  Theme defaults must evaluate without unused font-package selectors.
- `runtime-metadata` checks explicit Linux/Darwin profile metadata, enabled-only
  VM retention policy and effective overrides, without evaluating private data.
- `zsh-plugins` starts the pinned plugin set twice in an isolated pseudo-terminal,
  checks plugin functions and completion caching, and verifies that a generated
  hook fails on its first failing command. It needs no runtime network access.
  Normalized hook-name collisions fail evaluation only when Hey is enabled;
  distinct priorities and identical names in separate phases remain valid.
  `test_tools/test_shell_startup.py` additionally covers fresh/cached insecure
  completion paths, unsafe cache files/ancestors, independent PATH-installed Hey,
  configurable macOS auto-attach and generated user-only cleanup. Selector tests
  mock tmux; they never attach to or create a real session.
- `homelab-policy` evaluates server/agent presets with a synthetic secret provider,
  checking default and overridden secret names, coordinated K3s/Cilium pod CIDRs,
  service CIDRs and default/disabled Tailscale route advertisement.
- `sops-darwin` (native Darwin) checks the opt-in adapter against pinned upstream
  SOPS source and its real manifest validator. It covers protected paths for both
  stages and templates, identity-path rejection, native overrides, preserved
  store dependencies, launchd manifests, and provider-before-consumer activation.
  It does not decrypt credentials or mount storage. `user-file-installation`
  separately exercises directory preflight rejection without root privileges.
- `desktop-policy` exercises native Dock activation with mocked commands and
  checks neutral Zed defaults, explicit presets and individual overrides.
  It also checks native Docker-context ownership and opt-in Colima directories,
  executing directory creation with dry-run and existing-state fixtures.
  Its three-target Alacritty matrix checks enable/disable, Darwin Nix Apps
  registration, retained user installation, TERMINFO and shell/TOML overrides.
- `janet-vendor` rejects native Janet build outputs under shared source; these
  must be built per system instead of committed.
- `k3s-server-arch` verifies secure plain-server defaults and optional pinned
  addons for both aarch64 and x86_64 Linux hosts. Default/custom API ports and
  pod CIDRs must agree across the K3s command and generated HelmChart; conflicting
  flags, forced Helm values, disabled charts and unsupported IPAM are rejected.
- `k3s-addon-manifests` builds the pinned chart and bootstrap inputs on the
  native check platform, renders default/custom Helm charts, and validates agent
  API environment variables, the IPAM ConfigMap, images and CRD/Flux objects.
- `minimal-consumer` checks that an external consumer can opt out of Hey and
  workstation policy, choose its Home Manager version and retain its revision.
  It also forces Linux/Darwin activation generation with optional modules disabled.
  An independent-feature matrix enables tmux, Codegraph, Alacritty and Git on both
  platforms without consumer-supplied internal packages or workstation policy,
  forces their activation scripts, and checks default/Bash/Fish terminal settings.
  Git also works without Zsh under those shells; enabling Zsh still adds aliases.
- `lazy-outputs` ensures failing sibling checks/packages do not block host or
  unrelated package selection, including explicit platform filtering.
- `process-supervisor` checks native group cleanup for timeout, overflow, early
  command exit, control EOF, reader failure and abrupt Janet death, plus status,
  argv/environment/cwd, closed command stdin and bounded output/descriptor use.
  Its serial fixtures self-expire and run on both public CI platforms.
- `cli-behavior` exercises real CLI dispatch in isolated temporary consumer
  fixtures through `test_tools/run_cli_tests.py`: serial process-group workers,
  per-test deadlines, limited output/file descriptors, and stop-on-first-failure.
  The runner uses the native supervisor, not a second group-signalling loop.
  Tests cover malformed-protocol cancellation and the combined output cap.
  Detached test daemons still require their explicit fixture cleanup.
  `cli-contracts` separately executes all three Janet suite entrypoints (unit,
  generic CLI and UTM CLI) with a sanitized fixture environment and bounded
  supervisor per suite. It is built by public CI, not merely evaluated.
  Before those suites it runs five serial dispatcher regressions: optional-module
  failure isolation, metadata-only help/which, all command names and aliases,
  argument/status preservation, missing-module/registration failures, import
  caching and external dispatch. Only selected command implementations load.
  `runtime-inputs` tests descriptor-checked reads, secret-size limits, safe
  TOML/YAML parsing, redacted errors and effective OpenSSH Match/Include policy
  without loading private host keys or contacting a server.
  It also runs `test_ssh_diagnostics.py`: CA/certificate parsing, validity and
  signature checks, bounded Includes and conditional-policy refusal. CLI cases
  cover failed-scan redaction, neutral Codex expectations and shared SAML limits.
  It covers negative generations and nested repositories
  without activating systems or requiring UTM. A disposable local Nix store
  verifies real consumer evaluation and error propagation without network access.
  Mocked GC commands verify exact profile scope and failure ordering; VM plist
  tests inject conversion failures and verify byte-for-byte preservation.
  Retired SSH cleanup and swap operations must leave processes and editable
  files untouched. Variable tests check dry-run behavior, confined keys, atomic
  replacement, permissions, and failure preservation.
  ISO builds cannot target system profiles; hook failures stay retryable and
  concurrent duplicates serialize; EKS SSH arguments survive a remote shell;
  hook priorities ignore creation order and cleanup failures retain their status.
  EKS diagnostics never initialize VPN/kubeconfig state; login honors the declared
  provider and dry runs never open secret files. Process deadlines remain bounded
  without leaking into subsequent commands.
  Recognized options reject missing values before command bodies run; parser
  tests cover numeric defaults, repeated options, clustering and `--` forwarding.
  Routed interactive shells request an SSH terminal; read-only commands do not.
  SSH readiness deadlines reap stalled probes and bound polling sleeps. UTM
  retention tests cover opt-outs, malformed metadata, legacy/versioned contracts,
  explicit counts and configured usernames. Local keep-N planning covers sparse
  numbers, rollback, no-op plans, validation and mutation-free previews. UTM IP
  fixtures verify opt-in scans, bounded fan-out and a shared discovery deadline;
  all commands are mocked and no network probes run. Sync log tests include normal
  and failing builds, all verbosity levels and dry runs with synthetic NIX_CONFIG.
  Tmux projects select exact sessions;
  executable discovery skips directories, broken links and non-executable files.
  real isolated Nix tests cover input overrides, preservation of unrelated lock
  nodes, and evaluated host diagnostics. Template tests reject traversal and
  source-symlink escapes, preserve nonempty targets, and exercise local copying
  with spaces, leading dashes and colons in destination names. Copies from the
  read-only Nix store must be editable without manual permission changes.
  Cache tests cover invalid/empty/custom XDG roots and symlinks. Mocked VM creation
  checks build/convert/validation ordering, failure preservation, staged-image
  recovery, bounded waits and VM-name validation.
  Direnv tests verify nearest-file discovery, error propagation and dry runs.
  Watch tests verify source selection and use real Watchexec to check literal
  argument preservation, including project and developer watch paths, without
  starting a persistent watcher. Project discovery covers Git boundaries,
  non-Git ancestors, shell/Gradle/service-only projects and filesystem-root
  termination. Framework build tests check package selection, caller-local
  result links, both Nix and Nom, failure propagation and dry runs.
  External command dispatch preserves argv and exit status and never executes
  commands during dry runs. Private tmux servers exercise the shipped assets
  with custom XDG paths, quotes and shell expressions, both bundled themes,
  user-customized preferences and intercepted popups. Reload failure tests
  check flag cleanup and preserve the source error even if cleanup also fails.
  Real Nix selection covers dotted host/check/image names, spaces and literal
  backslashes. Mocked IP discovery covers Linux kernel-selected source addresses,
  missing routes/sources, dry runs, and unchanged macOS/public-address lookups.
- `tmux-status` builds and tests the Rust tmux status helper used by the tmux
  status bar.
- `mk-host-flake` verifies that an external-style host flake can consume `nixi`
  through `lib.mkHostFlake`, import an ordinary shared-policy input, accept both
  inline host descriptors and descriptor file paths, resolve module paths from
  both forms, and produce NixOS host configurations.
- `host-descriptor-contract` verifies the stable host descriptor API: descriptor
  files may return attrsets or functions, `target` defaults to `runtime`, valid
  non-runtime targets are preserved, and missing or unsupported fields are
  rejected during normalization.
- `external-host-flake` verifies the same contract through a real consumer
  `flake.nix` fixture, without requiring a fixture lock file or leaking raw
  input graphs as public outputs. It also verifies that the immutable consumer
  workspace and reusable framework roots remain separate and that no ambient
  checkout path enters the host argument contract.
- `generic-policy-input` verifies that shared policy is not special-cased to a
  `site` input name. Any ordinary flake input exposing `nixosModules` can be
  imported explicitly by the host descriptor and appears in `hey.modules`.
- `generic-darwin-policy-input` verifies the same ordinary-input contract for
  `darwinModules` and Darwin host descriptors.
- `root-host-flake` verifies that a host flake can consume only `nixi`, omit
  optional site inputs, derive its per-system outputs from the declared host
  systems, produce the expected host configuration, and avoid leaking
  framework-internal composition attrs as public outputs.
- `host-flake-systems` verifies that `mkHostFlake` still honors an explicit
  `systems` override for per-system outputs without inventing host
  configurations for platforms that have no matching host descriptors.
- `host-flake-overlays` verifies that overlays passed to `mkHostFlake` are
  applied consistently to host system evaluation and per-system package
  evaluation.
- `host-flake-packages` verifies that packages passed to `mkHostFlake` are
  available both as per-system flake outputs and as `hey.packages` inside host
  modules.
- `host-flake-apps` verifies that apps passed to `mkHostFlake` are available
  both as per-system flake outputs and as `hey.apps` inside host modules.
- `host-flake-devshells` verifies that dev shells passed to `mkHostFlake` are
  available both as per-system flake outputs and as `hey.devShell` inside host
  modules.
- `host-flake-module-outputs` verifies that modules passed to `mkHostFlake`
  are exported as reusable module outputs and can be imported by another host
  flake through an ordinary flake input.
- `local-extensions` verifies that host-local profiles and modules can be
  imported as ordinary Nix modules without extending `nixi`.
- `runtime-secret-paths` verifies Linux and Darwin option types reject store-backed,
  contextual and noncanonical secret paths while permitting runtime paths and
  public store inputs. It checks Git ancestor/descendant destination collisions.
- `secret-provider-boundary` verifies that runtime secret file options work
  without a SOPS input, and that SOPS-specific profiles only require SOPS when
  enabled. Identity selection suppresses implicit SSH key imports in age-file
  mode, supports explicit host-key mode and preserves native SOPS overrides.
- `network-service-integration` checks native Tailscale authentication, credential
  path transport, retry settings and native overrides. It executes the generated
  authentication/IP scripts with stubbed external commands, covering delayed
  readiness, missing addresses, literal arguments and atomic IP-file publication.
  Caddy's actual parser adapts evaluated configuration snippets to verify neutral
  defaults and the opt-in Gitea/Tailscale profile without requesting certificates.
  A both-Linux-architecture matrix compares the minimal Gitea adapter with native
  composition and checks explicit policy selection, compatibility defaults,
  native overrides, disable precedence and Tailscale/native composition. Native
  Python parses rendered evaluated Gitea settings for native, compatibility and
  overridden deployments. These fixtures do not execute Gitea or its upstream
  runtime configuration builder. Enabling Gitea alone must not open TCP firewall
  ports, and native service disablement remains authoritative. Linux VM boot,
  tailnet reachability, database/authentication/mail and data migration remain
  separate acceptance gates.
- `agent-integration` evaluates neutral OMP and opt-in workstation policy on both
  Linux architectures and Darwin, including ordinary disable/override precedence,
  nullable preferences, explicit model requirements, consumer-owned files and
  selected/other-user activation boundaries. It builds native YAML and checks
  parser round trips. Generated OMP activation runs against disposable settings
  with Home Manager's actual `run` helper, checking dry runs, writable private
  ownership, undeclared-value preservation and repeat activation. Focused sync
  helper regressions retain malformed YAML, unsafe path and legacy-link coverage.
  Generated RTK activation uses a mock binary to check the explicit Codex home,
  dry runs, missing commands and disabled integrations. The native ARM run records
  real untrusted-root rejection; separate guest coverage executes positive OMP
  helper and exact generated-hook boundaries. Real OMP application/concurrent-write
  acceptance remains separate.
- `agent-capability-manifest` verifies that agent modules render their generic
  command, directory, and file expectations into the runtime capability
  manifest while respecting disabled checks. It also enforces the versioned
  envelope and prevents generic fields from leaking back into specialized
  agent manifests.
- `workspace-flake` verifies a workspace layout where a root flake can
  aggregate framework, site, and host outputs without exposing raw input graphs
  as public outputs.
- `discovered-host-flake` verifies that a host flake can use
  `lib.mapHosts ./hosts` as the `mkHostFlake` host inventory, including nested
  grouping directories, and still derive per-system outputs from discovered
  descriptors.
- `merge-checks` verifies the workspace aggregation helper used to combine
  ordinary per-system flake check outputs.
  Duplicate check names fail without inspecting derivations; unrelated checks
  stay lazy. General attribute merges cover scalar/list/mixed-type precedence,
  nested sets and atomic derivation leaves.
- `map-hosts` verifies that host inventories can use flat host files and nested
  grouping directories without changing the final host names, that host files
  may return either descriptor attrsets or descriptor functions, and that
  duplicate host names are rejected. Grouped descriptors can import modules
  outside the hosts directory.
- `map-modules` verifies that recursive module discovery treats any directory
  containing `default.nix` as an entry point, stops recursion there, honors
  `.noload`, preserves relative imports, and rejects duplicate entry names
  including file/group collisions in both recursive output forms.

Command-wiring fixtures and their shared assertions live in `test/cli/`.
`bin/hey.d/check.janet` selects these suites lazily; Janet library tests remain
under `test/hey/` and behavioral subprocess tests under `test_tools/test_cli.py`.

The framework's `mkFlake` output contract is checked by `hey check framework`.
It derives the required current-system check names from regular `checks/*.nix`
files at the embedded framework root. Consumer `hey check eval` and `all` do not
require these internal outputs.
