# Publishing boundary

Publish Nixi from an explicitly reviewed source snapshot into a new repository.
Do not change a combined/private workspace repository to public. A flake `dir`
selector, `.gitignore`, subtree move, or deletion in a later commit does not hide
earlier commits, tags, author email addresses or private sibling files.

## Release files

`release-files.json` is the exact allowlist, with SHA-256 hashes and executable
bits. It intentionally excludes Git metadata, build outputs, generated Janet
manifests and the unverified wallpaper described in [NOTICE](../NOTICE.md).
The core Hey package explicitly installs `hey` and `myip`, not executables
discovered by copying every script in a directory. The approved `tmuxsel`
utility is exported and packaged separately. Other convenience scripts can be
preserved independently of that package. A lack of module references is not
evidence that an interactive command is unused, or a reason to delete it.
Review distribution and packaging of optional utilities separately.
The exporter uses no parent-directory discovery and never copies a Git history.
The manifest has a closed, versioned schema: unknown metadata and invalid field
types are rejected. Its contents are scanned too, including private deny-patterns.

```sh
python3 test_tools/test_release.py
python3 tools/release.py audit
python3 tools/release.py export --destination /absolute/new/path/nixi
```

The destination must not exist and must be outside the source tree. An export
contains only allowlisted source files and the manifest itself. No commit, remote,
archive, upload or system activation is performed. No filesystem owner metadata
is preserved. Export verification catches source changes during copying.
The export API audits the source independently and retains deny-patterns during
destination verification. An unsuccessful export must not be published.
Export reads regular files through no-follow directory/file descriptors and
checks the exact copied bytes against the manifest. The new destination remains
private (`0700`) until verification succeeds; a failed candidate stays private
for inspection. It never changes permissions on a source file or symlink target.

After editing approved files, inspect the diff, then refresh their hashes with
`python3 tools/release.py refresh --reviewed`. New paths require explicit edits
to the manifest; refresh never discovers or approves new paths automatically.
The manifest is a review record, not a signature or proof of review.

Use repeatable `--deny-pattern` arguments for private names, domains, account IDs
and home paths during a PRIVATE review. Do not commit those patterns or a report
containing matched values into the public tree. Diagnostics redact match values.
Common-key patterns cannot detect every credential or encoded secret. Run an
independent secret scanner against the exact exported directory as well.
The `publication-boundary` Nix check exports into its disposable build directory
and runs pinned Gitleaks with redacted output and the upstream rule set. It does
not scan or publish the private parent repository or Git history. Passing this
check still requires human review of private identifiers and host configuration.

## First-publication checklist

Plan the private reporting route described in [SECURITY.md](../SECURITY.md) before
publication; enable and verify it on the sanitized public repository before
announcing the release. Do not substitute a personal
address or claim that reporting is enabled without checking repository settings.

The exported `.github/workflows/public-checks.yml` runs automatically in a public
repository. A private repository requires a manual dispatch with
`sanitized_staging=true`: confirm it contains only the reviewed export, never
the combined workspace. This permits pre-publication native-runner validation.
It uses commit-pinned actions, read-only repository permissions,
no persisted checkout credentials, and no private caches, secrets or artifact
uploads. Linux and macOS jobs export again, evaluate all available checks, and
build every check classified as native. The macOS job also validates the opt-in
SOPS adapter with synthetic inputs. The `runtime-inputs`
check exercises credential and structured config parsers; `cli-contracts`
executes the Janet unit, generic CLI and UTM CLI suites
in addition to the Python behavioral tests. These must pass, not just evaluate.
The complete check inventory is classified in `test_tools/check-policy.json` as
native, evaluation-only, or VM-required. CI validates that inventory against the
source definitions, selects available native checks from Nix's platform output,
and builds them all. Unclassified, stale or duplicate entries fail before builds.
An empty native plan or a missing mandatory security/runtime check also fails.
This includes GnuPG permissions, Home Manager migration/collision tests and
desktop activation fixtures; their runtime tests must not be silently omitted.
VM boot tests remain separate and require a virtualization-capable Linux runner.
The workflow is inactive while nested in the private workspace. Adding it is not evidence of
a successful CI run; verify both native jobs before approving publication.

- Review every manifest addition and all source changes; scan hidden files too.
- Confirm license choice and upstream attribution; exclude unresolved assets.
- Verify no personal inventory, credential data, private input URLs, generated
  runtime manifests or local build artifacts entered the export.
- Test from the export with no parent host/site repository. Evaluate the synthetic
  consumer and build framework checks on supported native platforms.
- Initialize a NEW repository in the export. Select a public author identity and
  email explicitly; check local Git settings before the first commit.
- Review the staged diff and scan the staged snapshot. Ensure no parent history,
  tags, remotes, Git LFS objects, archives or attachments were imported.
- Ask for explicit approval of the destination repository and visibility before
  creating a remote or pushing. Never run a mirror push from the private repo.
- Public CI may build synthetic fixtures/framework outputs only. Keep personal
  host closures, build logs and private caches out of its inputs and uploads.

Fresh history avoids publishing private history; it does not erase it locally.
The private workspace remains the recovery source for omitted files. If history
is desired later, treat that as a separate full-history sanitization project.

See [security and ownership boundaries](security.md) for the trust model,
optional infrastructure presets, and isolated CLI-test runner.
