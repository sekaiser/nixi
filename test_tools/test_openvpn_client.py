"""Restricted OpenVPN client regressions with synthetic inputs only."""
import io
from pathlib import Path
import stat
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'tools'))
import openvpn_client as client


class ProtectedClient(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='nixi-openvpn-client-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.inputs = {'/config': b'client\ndev tun\nremote vpn.example.invalid 1194\n',
                       '/auth': b'synthetic-user\nsynthetic-password\n',
                       '/user': b' user with spaces \r\n', '/password': b' password \n',
                       '/ca': b'synthetic public certificate\n', '/key': b'synthetic private key\n'}
        self.reads = []

    def reader(self, path, private=False):
        self.reads.append((path, private))
        return self.inputs[path]

    def prepare(self, text=None, **kwargs):
        if text is not None:
            self.inputs['/config'] = text.encode()
        return client.prepare('/config', self.root, reader=self.reader,
                              **(kwargs or {'auth_file': '/auth'}))

    def test_snapshot_and_root_private_credentials(self):
        self.prepare('client\nremote "vpn.example.invalid" 1194\nca /ca\nkey /key\n',
                     username_file='/user', password_file='/password')
        self.assertEqual((self.root/'auth-user-pass').read_bytes(), b' user with spaces \n password \n')
        self.assertEqual((self.root/'input-0').read_bytes(), self.inputs['/ca'])
        self.assertEqual((self.root/'input-1').read_bytes(), self.inputs['/key'])
        config = (self.root/'client.conf').read_text()
        self.assertIn('remote "vpn.example.invalid" "1194"', config)
        self.assertIn('key "' + str(self.root/'input-1') + '"', config)
        self.assertNotIn('synthetic-password', config)
        self.assertEqual(self.reads, [('/config', True), ('/ca', False), ('/key', True), ('/user', True), ('/password', True)])
        self.assertTrue(all(stat.S_IMODE(p.stat().st_mode) == 0o400 for p in self.root.iterdir()))

    def test_scripts_plugins_includes_and_output_directives_rejected(self):
        for directive in ('up /payload', 'down /payload', 'plugin /payload', '--plugin /payload',
                          'config /other', 'cd /tmp', 'log /output', 'writepid /output',
                          'script-security 2', 'management 127.0.0.1 1000',
                          'iproute /payload', 'providers /payload', 'setenv OPENSSL_CONF /payload',
                          'tls-verify /payload', 'auth-user-pass /other'):
            with self.subTest(directive=directive):
                with self.assertRaises(ValueError):
                    self.prepare('client\n'+directive+'\n')
                self.assertEqual(list(self.root.iterdir()), [])

    def test_inline_and_connection_blocks_are_parsed_without_directive_smuggling(self):
        self.prepare('client\n<ca>\nSYNTHETIC-CERT\n</ca>\n<connection>\nremote vpn.example.invalid\n</connection>\n')
        before = (self.root/'client.conf').read_bytes()
        for text in ('<key>\nvalue\n', '<connection>\nremote vpn.example.invalid\n',
                     '<key>\n</key> trailing\nplugin /payload\n</key>\n',
                     '<key>\n</key>\x00\nplugin /payload\n</key>\n',
                     '<connection>\nplugin /payload\n</connection>\n',
                     '<unknown>\nvalue\n</unknown>\n'):
            with self.assertRaises(ValueError):
                self.prepare(text)
            self.assertEqual((self.root/'client.conf').read_bytes(), before)

    def test_unsafe_file_references_and_credentials_leave_previous_snapshot(self):
        self.prepare()
        before = {p.name:p.read_bytes() for p in self.root.iterdir()}
        for text in ('ca relative', 'crl-verify /directory dir', 'tls-auth /key 9',
                     'remote "unterminated', 'ca /ca\x00', 'remote host\t"bad\x1bvalue"',
                     'remote host\x0bclient', 'remote host\x0cclient'):
            with self.assertRaises(ValueError):
                self.prepare(text)
            self.assertEqual({p.name:p.read_bytes() for p in self.root.iterdir()}, before)
        self.inputs['/auth'] = b'one line only\n'
        with self.assertRaises(ValueError):
            self.prepare('client\n')
        self.assertEqual({p.name:p.read_bytes() for p in self.root.iterdir()}, before)

    def test_combined_auth_and_key_password_are_private_snapshots(self):
        self.inputs['/auth'] = b' user \r\n password \r\n'
        self.inputs['/key-password'] = b' key password \r\n'
        self.prepare('client\r\n', auth_file='/auth', key_password_file='/key-password')
        self.assertEqual((self.root/'auth-user-pass').read_bytes(), b' user \n password \n')
        self.assertEqual((self.root/'askpass').read_bytes(), b' key password \n')
        self.assertIn(('/key-password', True), self.reads)
        self.assertNotIn(' key password ', (self.root/'client.conf').read_text())

    def test_invalid_auth_and_aggregate_limits_fail_before_outputs(self):
        for options in ({}, {'username_file': '/user'},
                        {'auth_file': '/auth', 'username_file': '/user', 'password_file': '/password'}):
            with self.assertRaises(ValueError):
                client.prepare('/config', self.root, reader=self.reader, **options)
            self.assertEqual(self.reads, [])
        with patch.object(client, 'MAX_TOTAL', 4):
            with self.assertRaises(ValueError):
                self.prepare('client\n')
        self.assertEqual(list(self.root.iterdir()), [])

    def test_cli_errors_do_not_echo_inputs_or_exception_contents(self):
        with (patch.object(client, 'prepare', side_effect=PermissionError('SYNTHETIC_PRIVATE_VALUE')),
              patch('sys.stderr', new_callable=io.StringIO) as errors):
            self.assertEqual(client.main(['--config', '/config', '--destination', str(self.root),
                                          '--auth-file', '/auth']), 1)
        self.assertNotIn('SYNTHETIC_PRIVATE_VALUE', errors.getvalue())
        self.assertIn('PermissionError', errors.getvalue())

    def test_file_set_limit_and_destination_symlink_protection(self):
        with self.assertRaises(ValueError):
            self.prepare('ca /ca\n'*(client.MAX_REFERENCES+1))
        outside = self.root/'outside'
        outside.write_text('preserve')
        (self.root/'client.conf').symlink_to(outside)
        self.prepare('client\n')
        self.assertEqual(outside.read_text(), 'preserve')
        self.assertFalse((self.root/'client.conf').is_symlink())

    def test_input_ownership_and_confidentiality_contract(self):
        info = lambda uid, mode: SimpleNamespace(st_uid=uid, st_mode=stat.S_IFREG|mode)
        for uid, mode in ((1000, 0o600), (0, 0o660), (0, 0o622)):
            with self.assertRaises(PermissionError):
                client.check_input(info(uid, mode), False)
        client.check_input(info(0, 0o644), False)
        client.check_input(info(0, 0o600), True)
        with self.assertRaises(PermissionError):
            client.check_input(info(0, 0o644), True)

    def test_reader_uses_protected_descriptor_and_bounded_reads(self):
        class Input(io.BytesIO):
            def fileno(self): return 7
        with (patch.object(client, 'open_source', return_value=Input(b'x'*(client.SECRET_LIMIT+1))) as source,
              patch.object(client.os, 'fstat', return_value=SimpleNamespace(st_uid=0, st_mode=stat.S_IFREG|0o600))):
            with self.assertRaises(ValueError):
                client.read_protected('/fixture', True)
            source.assert_called_once_with('/fixture', 0)
        with self.assertRaises(ValueError):
            client.read_protected('relative')


if __name__ == '__main__':
    unittest.main()
