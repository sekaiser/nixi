# Pre-publication security review — 2026-09-10

Publication remains gated. This is a scoped source review and regression exercise,
not independent certification or a guarantee that all dependencies are secure.

## Scope

Inspected the release exporter/manifest, CI coverage policy, privileged user-file
installer and isolated Python launcher, SSH certificate preparation, runtime-secret
path validation, bounded input parsers, EKS credential transport and remote argument
quoting, native process supervisor and Janet bridge, and local profile mutations.

Threats considered: accidental private-source publication; symlink/path replacement
around privileged copies; executable environment injection; malformed/oversized
inputs; diagnostic secret disclosure; remote shell interpolation; leftover or
mis-targeted processes; false-positive diagnostics/CI; concurrent profile changes.
Consumer flakes, modules, hooks, project commands and selected binaries are trusted
executable inputs. Activation authority is administrative authority.

## Changes arising from review

- CI rejects an empty native plan and missing mandatory security/runtime checks.
- Project diagnostics fail for missing required tools; optional tools still warn.
- Sync activation and rollback share the existing removal/pruning lock. Profile
  rollback selects its target under the lock. Removal rechecks its selected-profile
  link before deleting generations. The lock is per runtime directory.
- SECURITY.md documents experimental support and a private reporting route that
  must be enabled and verified as part of the publication procedure.

No additional high-severity vulnerability was confirmed in the inspected paths.
This conclusion is limited to this scope, not every module or dependency.

## Verification and remaining limits

Focused synthetic tests cover required/optional tools, mutation lock presence and
release on failure, dry runs, retention, boot refresh, and log redaction. CI-policy
tests cover empty plans, mandatory-check omission and invalid classifications.
Security-focused Nix checks cover export/scanning, input parsing, privileged-file
boundaries, SSH certificates, process supervision and CLI contracts. Record actual
successful builds for the candidate: test existence or evaluation is not execution.

The documented trust boundaries still apply:

- Source traversal checks POSIX modes/owners, not permissive ACLs.
- Runtime-path validation cannot undo an earlier Nix store import or identify
  every runtime symlink into the store.
- Process groups do not contain deliberate escapes, existing daemon work,
  uninterruptible tasks, or a killed supervisor.
- Profile locks exclude other runtime directories, direct Nix commands, external
  rebuild tools and remote UTM operations. Do not mutate concurrently.
- External program output is not universally redacted. Review logs before sharing.
- Source CLI tests are not a sandbox. Prefer Nix-built synthetic checks; never
  supply live credentials or run broad tests as root.

## Release gates

1. Successful native Linux/macOS jobs on the same sanitized candidate, plus Linux
   VM boot verification where applicable. Local Darwin checks are insufficient.
2. Plan private reporting before publication; enable and verify it at launch,
   before announcing the public repository.
3. Confirm public identity, licensing/attribution and exact final export contents;
   repeat private-identifier and independent secret scans after final changes.
4. Publish fresh history from that export, never the combined workspace.

No complete transitive dependency/CVE audit, live infrastructure penetration test,
real-root exploitation or private-history review was performed. No remote was
created and nothing was uploaded.
