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

## Opt-in public maintenance workflow

`.github/workflows/dependency-maintenance.yml` runs only in a public repository
whose owner sets the repository variable `NIXI_DEPENDENCY_MAINTENANCE=true`.
It can run manually or on the example weekly schedule. It verifies/exports the
reviewed public layout first; private staging and consumer inventories are
deliberately unsupported. Change the schedule to your maintenance policy.

The workflow has read-only repository permissions and no deployment credentials.
It creates a seven-day artifact containing a lifecycle report, proposed package
input lock, patch, advisory output and completion status. The proposal only
updates the three Nixpkgs inputs, in a separate output file. The advisory job
scans the CURRENT public Linux Hey derivation/build dependencies, not every
module, platform, candidate update or consumer host. The scanner is selected
from that checkout's locked upstream Nixpkgs; it may need to be downloaded/built,
but the target system is never built or activated. Missing scanner support or
network failures require investigation, not treating an empty artifact as clean.

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
