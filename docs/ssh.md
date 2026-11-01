# SSH Certificates

`nixi` models OpenSSH certificates with separate user and host trust paths.
This avoids per-host `authorized_keys` sprawl and avoids trust-on-first-use
host-key prompts for managed machines.

This approach was inspired by Jan-Piet Mens' article
[SSH certificates: the better SSH experience](https://jpmens.net/2026/04/03/ssh-certificates-the-better-ssh-experience/),
which gives a practical walkthrough of OpenSSH user and host certificates.

The model is:

```text
user CA signs user public keys
servers trust the user CA with TrustedUserCAKeys

host CA signs server host public keys
clients trust the host CA with @cert-authority known_hosts entries
```

Keep user and host CAs separate. A single CA can technically sign both user and
host certificates, but separation gives clearer ownership and safer rotation.

## Boundaries

`nixi` provides the reusable mechanism:

- sign local user public keys during activation
- configure servers to trust user CAs
- configure clients to trust host CAs
- install or sign server host certificates
- diagnose local certificate and SSH tunnel state with `hey ssh doctor`

Host flakes and private site flakes provide policy:

- CA public keys
- CA private key secret locations
- host certificate principals
- certificate validity windows
- pre-signed host certificate files or SOPS-backed host certificate secrets

Private CA keys should not live in `nixi`.

## User Certificates

User certificates answer: "which users may this client authenticate as?"

On a client, configure a user certificate signer:

```nix
modules.services.ssh.userCertificates.work = {
  caKeyFile = config.sops.secrets."ssh/work_user_ca_ed25519".path;
  publicKeyFile = "${config.user.home}/.ssh/id_ed25519.pub";
  certificateFile = "${config.user.home}/.ssh/id_ed25519-cert.pub";
  principals = [config.user.name];
  identityPrefix = "${config.user.name}-${config.networking.hostName}";
  validity = "+30d";
  targetUser = config.user.name;
};
```

Locally signed user certificates are activation-only by default. Missing signing
inputs warn and skip; set `modules.services.ssh.userCertificates.work.required = true` to fail instead.

Certificate paths must be canonical absolute paths, without `.`/`..`, repeated
slashes, backslashes or control characters. Principals must be nonempty and
cannot contain commas or control characters. Multiple certificates require
distinct `certificateFile` paths; the single-certificate defaults are unchanged.
On Linux, user and host certificate destinations must also be distinct from
one another. These are lexical checks, not filesystem alias detection.

Opt into renewal independently of system rebuilds:

```nix
modules.services.ssh.userCertificateRenewal = {
  enable = true;
  intervalSeconds = 86400;
  # Linux only: declare the actual units providing your runtime CA key.
  dependencies = [];
};
```

Renewal uses a systemd timer on Linux and a root launchd daemon on macOS.
Choose an interval shorter than the certificate validity. A successful scheduler
run is not an expiry monitor: inspect certificates with `ssh-keygen -L -f PATH`
and monitor failed renewal jobs. On macOS, unavailable runtime secrets are retried
at the next interval; launchd does not use the Linux dependency list.
Prefer an external signer or pre-signed certificates when distributing a user CA
private key to client machines would grant excessive signing authority.

Installation preserves existing parent-directory permissions and creates new
directories privately. The immediate parent must be owned by the recipient,
not group/world writable, and not a symlink. A destination-file symlink is
replaced, never followed. Unsafe destinations fail without changing their mode.

Signing reads the user public key in a separate process after switching to
`targetUser`/`targetGroup`; a home-directory symlink cannot borrow root's access.
Key and certificate reads require regular files of at most 1 MiB. Each operation
has a 45-second deadline; signing is noninteractive and cannot invoke askpass.
Protected provider sources are required for CA reads, with root ownership when
the signer runs as root. Inputs are never included in error output or core dumps.
RSA, ECDSA and Ed25519 are supported. Security-key/FIDO certificates require
external management; unsupported formats fail without modifying the destination.

On a NixOS server or VM, trust the user CA:

```nix
modules.services.ssh = {
  enable = true;
  passwordAuthentication = false;
  trustedUserCAKeys = [
    "ssh-ed25519 AAAA... work user ssh ca"
  ];
};
```

For VM images, prefer the profile-level option:

```nix
modules.profiles.vm-image = {
  enable = true;
  trustedUserCAKeys = [
    "ssh-ed25519 AAAA... work user ssh ca"
  ];
};
```

This writes `TrustedUserCAKeys /etc/ssh/trusted_user_ca_keys.pem` into
`sshd_config`. The server no longer needs every client's public key in
`authorized_keys`.

## Host Certificates

Host certificates answer: "is this server really one of the hosts I trust?"

Generated host-certificate and client known-hosts paths are quoted for OpenSSH,
including spaces and literal quotes. Client trust file paths must be canonical
relative or absolute paths without control characters or backslashes. Percent
characters in the managed known-hosts filename remain literal; `${...}`
environment expansion is rejected because it would select a different file
than Home Manager installs.

Clients trust a host CA through managed `@cert-authority` entries:

```nix
modules.services.ssh.trustedHostCAKeys.work = {
  patterns = [
    "*.example.internal"
    "eks-bastion"
    "utm"
  ];
  publicKey = "ssh-ed25519 AAAA... work host ssh ca";
};
```

This writes `~/.ssh/nixi_known_hosts` with entries like:

```text
@cert-authority *.example.internal,eks-bastion,utm ssh-ed25519 AAAA... work host ssh ca
```

`nixi` does not overwrite an existing `~/.ssh/config` by default. Include the
managed known-hosts file from your own SSH config:

```sshconfig
Host *
  UserKnownHostsFile ~/.ssh/nixi_known_hosts ~/.ssh/known_hosts
```

If you want `nixi` to write a snippet for that line:

```nix
modules.services.ssh = {
  manageClientConfig = true;
  clientConfigFile = ".ssh/config.d/nixi-host-ca.conf";
};
```

Then include that snippet from your own `~/.ssh/config`:

```sshconfig
Include ~/.ssh/config.d/*.conf
```

## Server Host Certificates

Servers need a host certificate next to their host private key. Prefer deploying
a pre-signed certificate:

```nix
modules.profiles.vm-image.hostCertificates.ed25519 = {
  sourceFile = config.sops.secrets."ssh/hosts/eks-bastion_ed25519-cert.pub".path;
  certificateFile = "/etc/ssh/ssh_host_ed25519_key-cert.pub";
  principals = [
    "eks-bastion"
    "eks-bastion.example.internal"
  ];
};
```

The Linux SSH module installs the certificate and adds:

```sshconfig
HostCertificate /etc/ssh/ssh_host_ed25519_key-cert.pub
```

The pre-signed certificate must match `publicKeyFile`, have host type, a valid
signature and a current validity interval, and explicitly include every configured
principal. The provider remains responsible for the intended CA identity and
rotation; signature integrity validation alone does not select a trusted CA.
Malformed, expired, future-dated, wrong-key or wrong-type material is rejected
before replacement, preserving the previous certificate. The same validation
runs after local signing. Runtime inputs are bounded regular-file snapshots,
and both paths share the atomic replacement primitive.

For bootstrap or lab use, the host can sign its host public key before SSH starts:

```nix
modules.profiles.vm-image.hostCertificates.ed25519 = {
  caKeyFile = config.sops.secrets."ssh/work_host_ca_ed25519".path;
  publicKeyFile = "/etc/ssh/ssh_host_ed25519_key.pub";
  certificateFile = "/etc/ssh/ssh_host_ed25519_key-cert.pub";
  principals = [
    config.networking.hostName
  ];
  validity = "+52w";
};
```

This is convenient, but it puts host CA private material on the target machine.
Use pre-signed host certificates when the host CA should remain offline or
centralized.

On Linux, `nixi-ssh-host-certificates.service` runs after `sshd-keygen.service`
and, when present, `sops-install-secrets.service`, before sshd. It fails on missing
inputs instead of silently leaving a fresh host without its certificate. Keep
host-certificate destinations in root-owned directories, such as `/etc/ssh`.
Root destination traversal rejects symlink ancestors and group/world-writable
directories; existing directory permissions are preserved.
For another service-based secret provider, declare its unit explicitly:

```nix
modules.services.ssh.hostCertificateDependencies = ["site-secrets.service"];
modules.services.ssh.hostCertificateRenewalInterval = "daily";
```

A timer reruns the installer/signer at that interval and reloads an active sshd.
Choose an interval shorter than certificate validity. Pre-signed certificates
are recopied, not re-signed: their provider must supply replacements before
expiry. An unchanged Nix generation does not prevent periodic renewal.

With `services.openssh.startWhenNeeded = true`, installation is instead required
before `sshd.socket` opens. The socket starts after the certificate/secret
services rather than during early socket setup. Each per-connection daemon
reads the latest certificate; no daemon reload is needed in this mode.

User-certificate signing remains an activation operation. Its CA stays in a
root-owned staging context; final certificate installation runs as `targetUser`.
The same privilege-dropping installer handles Git secret files. Destination
directories must already be accessible to the recipient or creatable by them.
For privileged copies, the source must be an absolute regular file reached only
through root-owned directories without group/world write permission. The file
must be owned by root or the recipient and not group/world writable. Protected
SOPS-style symlinks into generation directories are supported, including relative
links. User-writable source directories, FIFOs and other special files are
rejected before any destination changes. This checks POSIX ownership/modes;
administrators must also avoid ACLs granting untrusted write access to those
directories or files. Invocations already running as the recipient use ordinary
filesystem access, but still require an absolute regular-file source.

## Signing Example

Sign a host public key outside the target host:

```sh
ssh-keygen \
  -h \
  -s ./host_ca_ed25519 \
  -I eks-bastion-20260707 \
  -n eks-bastion,eks-bastion.example.internal \
  -V +52w \
  -z 1001 \
  ./ssh_host_ed25519_key.pub
```

Inspect certificates:

```sh
ssh-keygen -L -f ~/.ssh/id_ed25519-cert.pub
ssh-keygen -L -f ./ssh_host_ed25519_key-cert.pub
```

## Diagnostics

Use:

```sh
hey ssh doctor
```

It reports:

- local user certificate presence and validity
- managed host CA trust file state
- local host certificate presence and validity
- unmanaged SSH processes
- tunnel-like SSH processes
- listening SSH sockets
- orphaned and zombie SSH processes

Installed default certificates must have the correct type, a valid embedded
signature and a current validity interval. Invalid installed material fails the
command even in quiet mode; absence remains optional. This does not establish
that a remote server trusts the issuer, accepts the principals, or that a custom
certificate path is installed. No private keys are read.

Managed CA entries are parsed as public keys. The client-config check establishes
an unconditional reference from `~/.ssh/config`, following Includes in lexical
order with first-value precedence. Relative Includes resolve under `~/.ssh`, as
specified by [OpenSSH](https://man.openbsd.org/ssh_config#Include). It is a static
subset check, not evaluation of a particular connection or full SSH syntax.
`Match`, conditional trust/Includes and connection-dependent paths report
unverified and return nonzero; no `Match exec`, proxy or network command runs.
Unrelated host-specific options do not prevent the unconditional check.
Inputs have a five-second deadline and a 1 MiB size limit (aggregate for config),
with at most 64 config files and 16 levels of nesting. Dry runs read no SSH files.

After changing certificate configuration:

```sh
hey check eval HOST
hey sync
hey ssh doctor
```

For VMs, also verify `sshd` after activation:

```sh
sudo sshd -t
```

## Rotation

Use short-lived user certificates, for example 30 days or less. Host
certificates can be longer lived, for example 52 weeks, but should still be
rotated deliberately.

Recommended rotation pattern:

- add new CA public key alongside old CA public key
- deploy new trust
- issue new certificates
- remove old CA public key after all clients and hosts have moved

This works for both `TrustedUserCAKeys` and `@cert-authority` host CA trust.
