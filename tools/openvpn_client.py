"""Prepare a restricted client config from protected, descriptor-read inputs.

OpenVPN config is privileged code. This adapter deliberately supports a client
subset: scripts, plugins, nested configs, management interfaces and arbitrary
file writes require a separately reviewed native OpenVPN service.
"""
import argparse
import io
import os
from pathlib import Path
import re
import shlex
import stat
import sys

from install_user_file import open_source, replace_file, root_destination
from runtime_input import FILE_LIMIT, SECRET_LIMIT, deadline, read_bounded

# Only directives with data arguments, never arbitrary executables or output
# paths. Re-emit parsed tokens canonically; never pass the original lines on.
DATA_OPTIONS = set("""
client tls-client dev dev-type proto remote remote-random remote-random-hostname
resolv-retry connect-retry connect-retry-max connect-timeout nobind local lport
rport port float persist-key persist-tun persist-local-ip persist-remote-ip
auth cipher data-ciphers data-ciphers-fallback auth-nocache auth-retry auth-token
remote-cert-tls remote-cert-ku remote-cert-eku verify-x509-name peer-fingerprint
tls-version-min tls-version-max tls-cipher tls-ciphersuites tls-timeout key-direction
reneg-sec reneg-bytes reneg-pkts hand-window tran-window tls-exit pull pull-filter
route route-ipv6 route-gateway route-delay route-metric route-nopull route-noexec
redirect-gateway redirect-private dhcp-option ifconfig ifconfig-ipv6 topology
ping ping-exit ping-restart ping-timer-rem keepalive explicit-exit-notify
tun-mtu tun-mtu-extra link-mtu mssfix fragment mtu-disc sndbuf rcvbuf fast-io
verb mute mute-replay-warnings allow-compression compress comp-lzo
socket-flags tcp-nodelay connect-freq remap-usr1 block-outside-dns
""".split())
FILE_OPTIONS = {
    'ca': False, 'cert': False, 'extra-certs': False, 'dh': False,
    'key': True, 'pkcs12': True, 'tls-auth': True, 'tls-crypt': True,
    'tls-crypt-v2': True, 'secret': True, 'crl-verify': False,
}
INLINE_OPTIONS = set(FILE_OPTIONS) | {'peer-fingerprint'}
MAX_REFERENCES = 32
MAX_TOTAL = 16 * FILE_LIMIT


def check_input(info, private):
    if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
        raise PermissionError('OpenVPN inputs must be root-owned regular files without group/world write permission')
    if private and info.st_mode & 0o077:
        raise PermissionError('OpenVPN config and credentials must be root-private')


def read_protected(path, private=False):
    if not os.path.isabs(path):
        raise ValueError('OpenVPN input paths must be absolute')
    # Root's source walker pins every directory, follows only protected provider
    # links and rechecks file identity after a no-follow open. Never stat/open
    # the source a second time after validating this descriptor.
    with open_source(path, 0) as incoming:
        info = os.fstat(incoming.fileno())
        check_input(info, private)
        return read_bounded(incoming, SECRET_LIMIT if private else FILE_LIMIT)


def quote(value):
    if any(ord(c) < 32 or ord(c) == 127 for c in value):
        raise ValueError('OpenVPN arguments must not contain control characters')
    return '"' + value.replace('\\', '\\\\').replace('"', '\\"') + '"'


def one_line(data):
    if data.endswith(b'\n'):
        data = data[:-1]
        if data.endswith(b'\r'):
            data = data[:-1]
    if not data or any(c in data for c in (b'\n', b'\r', b'\0')):
        raise ValueError('OpenVPN credential must contain one nonempty line')
    return data


def prepare(config_file, destination, *, auth_file=None, username_file=None,
            password_file=None, key_password_file=None, reader=read_protected):
    if bool(username_file) != bool(password_file) or not (auth_file or username_file):
        raise ValueError('Choose a combined credential file or both split inputs')
    if auth_file and username_file:
        raise ValueError('Combined and split credentials are mutually exclusive')
    # Bound total input work as well as each read. All inputs are validated
    # before touching the current prepared files.
    total = 0
    def read(path, private=False):
        nonlocal total
        data = reader(path, private)
        total += len(data)
        if total > MAX_TOTAL:
            raise ValueError('OpenVPN input set exceeds its limit')
        return data

    source = read(config_file, True).decode('utf-8')
    if any((ord(c) < 32 and c not in '\r\n\t') or ord(c) == 127 for c in source):
        raise ValueError('OpenVPN config must not contain control characters')
    output = []
    staged = {}
    connection = False
    inline = None
    for raw in source.splitlines():
        line = raw.strip()
        if inline:
            if line == '</' + inline + '>':
                output.append(line)
                inline = None
            else:
                if '<' in raw or '>' in raw:
                    raise ValueError('Ambiguous OpenVPN inline block delimiter')
                output.append(raw)
            continue
        if not line or line.startswith(('#', ';')):
            continue
        tag = re.fullmatch(r'<([a-z][a-z0-9-]*)>', line)
        if tag:
            name = tag[1]
            if name == 'connection' and not connection:
                connection = True
            elif name in INLINE_OPTIONS and not connection:
                inline = name
            else:
                raise ValueError('Unsupported OpenVPN block')
            output.append(line)
            continue
        if line == '</connection>' and connection:
            connection = False
            output.append(line)
            continue
        lexer = shlex.shlex(line, posix=True)
        lexer.whitespace_split = True
        lexer.commenters = ''
        fields = list(lexer)
        option, args = fields[0].removeprefix('--'), fields[1:]
        if option in FILE_OPTIONS:
            if len(args) not in (1, 2) or (len(args) == 2 and (option not in ('tls-auth', 'secret') or args[1] not in ('0', '1'))):
                raise ValueError('Unsupported OpenVPN file directive')
            if len(staged) >= MAX_REFERENCES or not os.path.isabs(args[0]):
                raise ValueError('OpenVPN file references must be bounded absolute paths')
            name = 'input-' + str(len(staged))
            staged[name] = read(args[0], FILE_OPTIONS[option])
            args[0] = str(Path(destination)/name)
        elif option == 'script-security':
            if args not in (['0'], ['1']):
                raise ValueError('OpenVPN scripts are not supported')
        elif option not in DATA_OPTIONS:
            raise ValueError('Unsupported OpenVPN directive')
        output.append(option + ''.join(' ' + quote(arg) for arg in args))
    if inline or connection:
        raise ValueError('Unclosed OpenVPN block')
    if username_file:
        username = one_line(read(username_file, True))
        password = one_line(read(password_file, True))
    else:
        lines = read(auth_file, True).split(b'\n')
        if lines[-1] == b'':
            lines.pop()
        if len(lines) != 2:
            raise ValueError('OpenVPN combined credentials must contain two lines')
        username, password = (one_line(line + b'\n') for line in lines)
    staged['auth-user-pass'] = username + b'\n' + password + b'\n'
    output += ['auth-user-pass ' + quote(str(Path(destination)/'auth-user-pass')), 'auth-nocache']
    if key_password_file:
        staged['askpass'] = one_line(read(key_password_file, True)) + b'\n'
        output.append('askpass ' + quote(str(Path(destination)/'askpass')))
    staged['client.conf'] = ('\n'.join(output) + '\n').encode()
    # Production uses a root-owned systemd RuntimeDirectory. The pinned
    # destination walk rejects writable/symlinked parents and does not follow
    # existing output links. Write the config last, after all referenced inputs.
    directory = root_destination(Path(destination)/'client.conf')
    try:
        for name, data in staged.items():
            replace_file(io.BytesIO(data), directory, name, 0o400)
    finally:
        os.close(directory)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('config', 'destination'):
        parser.add_argument('--' + name, required=True)
    for name in ('auth-file', 'username-file', 'password-file', 'key-password-file'):
        parser.add_argument('--' + name)
    args = parser.parse_args(argv)
    try:
        with deadline(5):
            prepare(args.config, args.destination, auth_file=args.auth_file,
                    username_file=args.username_file, password_file=args.password_file,
                    key_password_file=args.key_password_file)
    except (OSError, ValueError) as error:
        print('OpenVPN protected client preparation failed (' + type(error).__name__ +
              '); require protected root-owned inputs and supported client directives. Input values are withheld.', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
