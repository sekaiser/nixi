# Read-only remote probe. -T enables -C on portable OpenSSH; -G exits after
# config parsing, before host-key loading. Never add sudo for this diagnostic.
set -eu
set -f
IFS=' '
set -- ${SSH_CONNECTION-}
if [ "$#" != 4 ]; then
  echo 'SSH policy verification requires SSH_CONNECTION from the current session' >&2
  exit 1
fi
case "$1$3" in *[!0-9a-fA-F:.]*) echo 'Invalid SSH connection addresses' >&2; exit 1;; esac
case "$2$4" in *[!0-9]*) echo 'Invalid SSH connection ports' >&2; exit 1;; esac
ssh_policy_user=$(id -un)
case "$ssh_policy_user" in ''|*[!a-zA-Z0-9_.-]*) echo 'Unsupported SSH policy username' >&2; exit 1;; esac
if ! ssh_policy_config=$(/run/current-system/sw/bin/sshd -T -G -f /etc/ssh/sshd_config \
  -C "user=$ssh_policy_user,addr=$1,host=$1,laddr=$3,lport=$4" 2>/dev/null); then
  echo 'Cannot inspect effective SSH policy: sshd -T -G and readable configuration (including Includes) are required' >&2
  exit 1
fi
ssh_policy_dns=
ssh_policy_password=
while read -r key value remainder; do
  case "$key" in
    usedns) ssh_policy_dns=$value ;;
    passwordauthentication) ssh_policy_password=$value ;;
  esac
done <<EOF
$ssh_policy_config
EOF
# With UseDNS=yes the server's forward-confirmed reverse lookup is not exposed
# in SSH_CONNECTION. Do not guess the Match Host input and certify a result.
if [ "$ssh_policy_dns" != no ]; then
  echo 'Cannot certify Match Host policy with UseDNS enabled; verify manually or configure UseDNS=no' >&2
  exit 1
fi
case "$ssh_policy_password" in
  yes|no) printf '%s\n' "$ssh_policy_password" ;;
  *) echo 'OpenSSH did not return a recognized password authentication policy' >&2; exit 1 ;;
esac
