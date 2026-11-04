# Dependency maintenance

Nixi provides update/inspection mechanisms; consumers own their package snapshots,
review cadence and deployment approval. Reproducible pins are not an ongoing
security-update service. `hey sync` builds existing pins; it does not update them
or run advisory scans. Never publish a private host lock/report merely because
the framework itself is public.

## Upstream first, temporary overrides second

Dependency overrides are **disabled by default**, including for Nixi's own
packages, checks and dev shells. `mkHostFlake` applies only explicitly selected
overlays; importing Nixi or running an advisory report does not enable them.
To opt in for an external consumer, add this argument to `mkHostFlake`:

```nix
overlays.security = inputs.nixi.overlays.security;
```

For an embedded workspace using `mkFlake`, explicitly include
`security = import ./nixi/overlays/security.nix;` in the workspace overlay set.
Remove that selection to return to upstream packages. Large dependency rebuilds
are a tradeoff the consumer chooses, not an implicit cost of using the framework.
Turning off an override does not resolve the associated advisories.

The opt-in OpenSSL catalog now sets a 3.6.5 floor for older 3.6 recipes.
The default reviewed snapshots already provide the September fixes through
OpenSSL 3.6.5 (stable) or 3.5.9 (unstable), so they do not need this overlay.

1. Prefer a reviewed Nixpkgs revision containing the necessary fixes. Update the
   relevant inputs with `hey pull nixpkgs nixpkgs-darwin nixpkgs-unstable`, inspect
   the lock diff, then evaluate/test the affected platforms. Upstream binaries
   may already be cached; cached patched builds are not less secure simply
   because they were built elsewhere by a trusted builder.
2. If suitable upstream pins lack a needed fix, use a narrowly scoped temporary
   override. Record the source hash, upstream advisories, rationale, validation,
   review date and removal condition in `security/overrides.json`. The OpenSSL
   overlay reads its pin from this record. A review deadline does not silently
   disable a fix or automatically alter a build. Other OpenSSL branches and
   bundled copies need separate review.
3. Run `hey sync plan` before committing to expensive host builds. Build/test the
   candidate, deploy explicitly, and restart affected processes. Inspect actual
   runtime dependencies afterwards; a successful build alone is not remediation.
4. Remove an override once reviewed upstream snapshots provide the fixes across
   the supported package contexts. Do not keep a stale minimum version as a
   permanent security claim. Nixpkgs may backport patches without bumping the
   upstream version: inspect patch provenance before suppressing a finding.

## Offline lifecycle report

From a public Nixi checkout:

```sh
python3 tools/dependency_report.py --lock flake.lock --max-age-days 30
```

For an embedded checkout the script is `nixi/tools/dependency_report.py`; point
`--lock` at the consumer lock. The report resolves the three named Nixpkgs inputs
and follows links, reporting revisions/ages without copying source URLs, local
paths or unrelated private inputs. It also reports review deadlines for the
available override catalog, not whether any override is active on a host.
Consumers can select `--overrides` and their maximum pin age.

Exit codes: 0 means no lifecycle review is due, 1 requests review (old, missing or
future pin timestamps, no recognized package inputs, or an override deadline),
and 2 means invalid/unreadable input. None means "no vulnerabilities". This tool
is offline and does not evaluate a flake, update locks, scan CVEs or change state.
The default 30-day threshold is a review prompt, not an acceptable delay for a
known urgent vulnerability. Critical advisories need prompt assessment.

## Package selection

The framework's reviewed package snapshots are:

| Input | Revision | Selected OpenSSL |
| --- | --- | --- |
| Stable Linux and Darwin | `9bb52223f4f6a0cc606fd0852d8784f896c137d5` | 3.6.5 |
| Unstable | `0bb2eedc20e4739f29e8045034f2828ad7054f8f` | 3.5.9 |

These versions include the fixes from the upstream
[August](https://openssl-library.org/news/secadv/20260825.txt) and
[September](https://openssl-library.org/news/secadv/20260929.txt) advisories.
The Darwin input deliberately uses the reviewed general stable snapshot to
obtain Node 24.22.1, retaining its declared update channel and follows graph.
Review Node again when refreshing that channel; a newer lock timestamp alone
is insufficient. All other input identities are retained.

The Emacs recipe preserves the four inherited upstream patches and appends
whole-string TRAMP username validation and canonical literal CA-path handling.
Doom's selected external GNU ELPA Flymake 1.4.7 is checksum-verified and repacked
with the trusted-backend guard, retaining normal install/native phases. See
[editor behavior and checks](doom-emacs.md). Optional diagnostic-region and
callback behavior changes are excluded.

Source integration and successful checks do not change an already running host.
Deployment, service restarts and live application checks remain explicit
operational steps.

## Explicit advisory scanning

Install `vulnix` from a reviewed, pinned package set when you choose to scan. Nixi
does not install it on every host or launch a scan during shell startup/sync.
Then run `hey security scan /nix/store/HASH-NAME --json` against the selected
derivation/output. This includes build dependencies by default, not just runtime
libraries. To select runtime-only scans or reviewed suppressions, invoke the
scanner directly using its version's documented options.

[Vulnix](https://github.com/nix-community/vulnix) downloads advisory data and
matches it locally using package-name/version heuristics. It can misidentify
packages, miss bundled dependencies, and infer fixes from CVE-named patches.
Treat results as review candidates, not exploitability findings or certification.
Network/database failures and missing derivation metadata are not clean scans.
Check source provenance and the scanner's coverage on the actual target.

Keep any backport/false-positive suppressions in an explicitly reviewed consumer
file. Scope each to the exact package/version and CVE IDs, include an `until`
date, explanation and upstream patch/advisory URL. Do not suppress an entire
package family or accept automatically generated suppressions without review.
Private reports and suppression notes can reveal installed software, store paths
or endpoints; never upload them through the public framework workflow.

## Public coverage inventory and scan runner

`security/dependency-coverage.json` classifies every public package definition
and records component sources, representative targets and exclusions. Adding a
package without classifying it fails the mandatory `dependency-coverage` check.
The inventory binds its source references to the reviewed release manifest,
coverage policy and lock hashes. It includes 169 entries from the committed
MemoryCore npm lock, including development/optional flags; the npm audit itself
omits development dependencies. This is a coverage inventory, not a complete
resolved SBOM.

The selected Nix roots are:

| Scope | Selected roots |
| --- | --- |
| Every supported system | Twelve executable/runtime framework packages, plus the actual module's default Emacs package |
| Both Linux architectures | Default Caddy, Docker, Gitea, K3s and Tailscale packages from synthetic public configurations |
| Separate npm audit | The committed public MemoryCore lock, without installing packages or executing scripts |

There are 13 roots on Darwin and 18 on each Linux architecture, before duplicate
derivations are coalesced for scanning. `default` aliases Hey; Humanizer/taste are
data-only and the Janet runtime library is covered through Hey. Package metadata
is evaluated with IFD, local jobs and builders disabled. No target output, host
closure, service, image or private consumer is built or activated.

Inventory/exclusions also identify the pinned Janet sources, Doom configurations,
Cilium/Gateway API recipe and opaque Codegraph bundle. Complete resolved Doom
Lisp/grammar packages, OCI layers and bundled native libraries remain gaps.
Neither parent-package matching nor chart/source inventory establishes coverage
of every embedded component. Private inputs, arbitrary consumer packages,
Homebrew/external executables and running host/cluster selections are excluded.
The actual dependency update/remediation work remains separate.

From the reviewed public source, write a new offline report:

```sh
python3 tools/dependency_scan.py inventory --output /tmp/nixi-inventory.json
```

To run selected advisory scans with tools from a reviewed package snapshot:

```sh
python3 tools/dependency_scan.py nix --system x86_64-linux \
  --scanner /absolute/path/to/vulnix --output /tmp/nixi-advisories.json
python3 tools/dependency_scan.py npm --npm /absolute/path/to/npm \
  --output /tmp/nixi-npm-audit.json
```

Reports require new filenames and default to mode 0600. Before any Nix evaluation
or scanner execution, the runner stages a verified allowlist-only export; ignored
working files are not imported into the store or submitted to a registry. The
npm step uses only the public manifest/lock in a disposable directory, empty npm
config files and no inherited npm auth/config variables. It sends that public
dependency description to `registry.npmjs.org`, runs no scripts, performs no
install/fix and checks that its scratch lock remains unchanged.

Exit 0 means inventory succeeded or the selected scan finished with no matches;
1 means validated advisory candidates; 2 means incomplete/refused. Every report
retains explicit exclusions and representative-only scope. `asOf` is execution
time, not proof that an advisory database is current. Unknown/malformed output,
inconsistent exit/count data, scanner diagnostics, missing tools, evaluation,
network and timeout failures cannot become a no-match report. The pinned Vulnix
uses exit 2 for findings and some errors, so JSON/diagnostics are checked too.
Npm results retain package, severity and validated GHSA/package references;
Vulnix results retain package versions, public derivations and CVE identifiers.
Raw diagnostics, titles, exception text and unvalidated payloads are withheld.

Commands have bounded file-backed captures and a ten-minute per-command timeout.
Process-group cleanup does not contain work deliberately detached by an external
tool or an uninterruptible kernel operation. These source/configuration and
synthetic protocol tests do not establish live advisory-feed availability,
scanner recall, candidate-pin acceptance or remediation of a deployed process.

## MemoryCore HTTP dependencies

The integrated production npm lock uses Undici 8.12.3 at the root and 6.29.1
in both nested locations. Parent dependency ranges and unrelated lock entries
are retained, and `npmDepsHash` matches the updated graph.

The stable package snapshot supplies Node 24.22.1, whose upstream
[security release](https://nodejs.org/en/blog/release/v24.22.1) includes bundled
Undici 7.30.1. Updating the npm copies alone did not fix Node's separate global
fetch implementation. The harmless data-URL regression rejects an incorrect
uppercase integrity digest for every npm copy and bundled fetch, corresponding
to the maintainer's [SRI advisory](https://github.com/nodejs/undici/security/advisories/GHSA-f72v-6w45-q472).

Mandatory native `agent-memory` CI runs `probe_memory_http.mjs --require-bundled`
against the built Core and its actual Node runtime. The test requires no network
listener or private configuration. A clean npm audit covers the submitted lock,
not every bundled library, consumer path or running process. The optional
three-system advisory workflow and its documented exclusions still apply.

## Opt-in public maintenance workflow

`.github/workflows/dependency-maintenance.yml` runs only in a public repository
whose owner sets the repository variable `NIXI_DEPENDENCY_MAINTENANCE=true`.
It can run manually or on the example weekly schedule. It verifies/exports the
reviewed public layout first; private staging and consumer inventories are
deliberately unsupported. Change the schedule to your maintenance policy.

The workflow has read-only repository permissions and no deployment credentials.
It creates seven-day artifacts containing lifecycle/coverage inventories,
proposed package input lock/patch, normalized scan reports and completion status.
The proposal only updates the three Nixpkgs inputs in a separate output file.
An independent matrix scans CURRENT public derivation/build dependencies for
all three supported systems, including the representative defaults above.
A separate step audits the committed MemoryCore npm lock. Matrix failure does
not cancel the other platforms. Scanner/npm tools come from that checkout's
locked upstream Nixpkgs; acquisition can download/build those tools, while scan
targets are never realized. Failures before a scanner report exists produce an
explicit machine-readable `incomplete` report. Findings/incomplete scans fail
the attention gate; an empty/missing artifact cannot count as success.

No branch, PR, merge or deployment is created. Review the artifact and job logs,
apply the patch locally if appropriate, run native checks, review remaining
explicit pins below, then refresh the publication manifest with `--reviewed`.
The artifact alone is not a tested release. Enabling the workflow or uploading
anything is a separate repository-owner action; adding this file locally does
not schedule work on a user's machine.

## Other manually pinned dependencies

Updating `flake.lock` does not update every dependency. The Cilium/Gateway API
pair is recorded in `lib/internal/addon-pins.nix`; the chart and CRDs are built
from those hashes. Other explicit pins live in `packages/codegraph.nix`,
`packages/hey-janet-deps.nix` and `modules/shared/editors/emacs.nix`. Review these
when preparing releases, not only the flake inputs. Vendor provenance is listed
in `NOTICE.md`.

`checks/sops-darwin.nix` has a test-only SOPS source pin. It exercises the optional
adapter against upstream's real Darwin manifest builder and validator, without
making SOPS a core flake input. Consumers own their runtime provider pin; changing
it requires rechecking the adapter's manifest-construction interface.

## Cilium and Gateway API

The default pair is Cilium **1.19.7** and Gateway API **1.4.1**, reviewed on
2026-09-09. Cilium's [maintained-branch list](https://github.com/cilium/cilium)
includes 1.19, and its [versioned Gateway API documentation](https://github.com/cilium/cilium/blob/v1.19.7/Documentation/network/servicemesh/gateway-api/gateway-api.rst)
specifies Gateway API 1.4.1. Its [tested Kubernetes matrix](https://github.com/cilium/cilium/blob/v1.19.7/Documentation/network/kubernetes/compatibility.rst)
covers 1.32–1.35, including the pinned K3s default (1.35). Cilium 1.18 is still
maintained but its [tested matrix](https://github.com/cilium/cilium/blob/v1.18.13/Documentation/network/kubernetes/compatibility.rst)
stops at Kubernetes 1.33, so it is not the
default here. This is not a promise that the pair will remain current.

Before each public release:

1. Check the upstream [support policy](https://github.com/cilium/cilium/blob/main/SECURITY.md)
   and [security advisories](https://github.com/cilium/cilium/security/advisories).
2. Select a compatible chart/CRD pair and review its upgrade notes. Fetch both
   inputs and record their independently verified unpacked hashes in the pin file.
3. Build `k3s-addon-manifests` and `k3s-server-arch`. These check the rendered agent
   image/version/digest, CRD bundle version, and effective K3s minor version against
   recorded compatibility matrix. Run cluster preflight/connectivity tests
   separately on disposable infrastructure; successful Helm rendering does not
   prove a safe live upgrade.
4. Update these review notes and migration guidance, inspect the diff, then
   refresh the publication manifest. Never automatically apply cluster updates.

Consumers can provide another reviewed pair without patching Nixi:

```nix
modules.profiles.k3s-cilium = {
  chartPackage = myPinnedChart;
  gatewayAPIManifest = myPinnedCRDManifest;
};
```

Native `services.k3s.autoDeployCharts.cilium.package` and
`services.k3s.manifests.nixi-gateway-api.source` assignments also take precedence.
Compatibility and security review of replacements belong to their owner.

Existing clusters must follow the [1.18 upgrade guide](https://docs.cilium.io/en/v1.18/operations/upgrade/)
and then the [1.19 upgrade guide](https://docs.cilium.io/en/v1.19/operations/upgrade/),
including their preflight, Kubernetes and source-version requirements. Do not
activate the new default directly over a 1.17 cluster: minor versions must be
upgraded sequentially, with explicitly selected intermediate packages/manifests
and appropriate Kubernetes versions. A successful Nix build does not validate
that migration. Back up cluster state and arrange a recovery path before changing
the CNI. No migration command, cluster access or deployment
is performed by Nixi's build checks.
