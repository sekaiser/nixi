# Security policy

## Release status and support

Nixi is experimental. No stable release, compatibility guarantee, or long-term
security-support branch is currently offered. Reports against the latest
published revision are welcome; fixes may require upgrading. Pin revisions and
review migration notes before upgrading. Optional infrastructure adapters need
validation on your own platform before use.

## Private vulnerability reports

As part of first publication, the maintainer must enable GitHub private
vulnerability reporting on the new, sanitized public repository and verify the
reporting route before announcing the release. See
[GitHub's reporting documentation](https://docs.github.com/en/code-security/how-tos/report-and-fix-vulnerabilities/report-privately).
Once enabled, use that repository's **Security → Report a vulnerability** action.
If the action is unavailable, do not put sensitive details in a public issue:
ask for a private reporting channel without including the vulnerability details.
There is no published response-time SLA.

Include the affected revision, platform, preconditions, impact, and a minimal
reproduction using synthetic data. Never send private host configurations,
credentials, real certificates/keys, complete environment dumps, or private
repository history. Do not test against systems you do not own or administer.

## Boundaries

Read [the trust model](docs/security.md) and [publication procedure](docs/publishing.md).
Nixi is not a sandbox for untrusted flakes, modules, hooks, or project commands.
Its process supervisor is a cleanup mechanism, not an OS containment boundary.
Permission to activate a user-built system is administrative authority.

Passing automated checks or a source review is not a certification of security.
Only a separately reviewed, allowlisted export is eligible for publication;
the maintainer's combined workspace and Git history are never release artifacts.
