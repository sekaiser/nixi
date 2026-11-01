"""Bounded input/parser regressions; only synthetic files and no live services."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import agent_config
import runtime_input


class RuntimeInputs(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="nixi-input-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.file = self.root / "input"

    def test_regular_provider_links_limits_and_special_files(self):
        self.file.write_bytes(b" value \r\n")
        link = self.root / "provider-link"
        link.symlink_to(self.file)
        self.assertEqual(runtime_input.read_regular(link), b" value \r\n")
        with self.assertRaises(ValueError):
            runtime_input.read_regular(link, 3)
        fifo = self.root / "fifo"
        os.mkfifo(fifo)
        for path in (fifo, self.root, "/dev/null"):
            with self.subTest(path=str(path)), self.assertRaises(ValueError):
                runtime_input.read_regular(path)

    def test_cli_preserves_whitespace_and_redacts_invalid_bytes(self):
        for data in (b" value \r\n", b"\xffSYNTHETIC_PRIVATE_VALUE", b"x" * 65537):
            self.file.write_bytes(data)
            result = subprocess.run([sys.executable, runtime_input.__file__, str(self.file)],
                                    capture_output=True, text=True, timeout=3)
            if data == b" value \r\n":
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(result.stdout), " value \r\n")
            else:
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
                self.assertNotIn("SYNTHETIC_PRIVATE_VALUE", result.stderr)

    def test_codex_comments_quoted_keys_missing_and_disabled_entries(self):
        expected = {"plugins": ["plugin@fixture"], "mcpServers": ["fixture"]}
        cases = [
            ('# [mcp_servers.fixture]\n# [plugins."plugin@fixture"]\n', "missing", "missing"),
            ('[mcp_servers."fixture"]\ncommand="tool"\n[plugins."plugin@fixture"]\nenabled=true\n', "configured", "configured"),
            ('[mcp_servers.fixture]\nenabled=false\n[plugins."plugin@fixture"]\nenabled=false\n', "disabled", "disabled"),
            ('[mcp_servers.fixture]\nenabled="false"\n', "malformed", "missing"),
            ('mcp_servers = "invalid"\n', "malformed", "missing"),
        ]
        for content, mcp, plugin in cases:
            self.file.write_text(content)
            result = agent_config.inspect("codex", self.file, expected)
            self.assertEqual(result["mcpServers"]["fixture"], mcp)
            self.assertEqual(result["plugins"]["plugin@fixture"], plugin)

    def test_omp_checks_the_requested_role_not_comments_or_other_fields(self):
        for content, status in [
            ('# expected-model\nmodelRoles:\n  other: expected-model\n', "missing"),
            ('modelRoles:\n  slow: wrong-model\n', "mismatched"),
            ('modelRoles:\n  slow: expected-model\n', "configured"),
        ]:
            self.file.write_text(content)
            result = agent_config.inspect("omp", self.file, {"modelRoles": {"slow": "expected-model"}})
            self.assertEqual(result["modelRoles"], {"slow": status})

    def test_parser_errors_never_echo_configuration_values(self):
        for kind, content in [("codex", '[SYNTHETIC_PRIVATE_VALUE'),
                              ("omp", 'field: [SYNTHETIC_PRIVATE_VALUE'),
                              ("omp", '!!python/object/apply:os.system ["false"]')]:
            self.file.write_text(content)
            result = subprocess.run([sys.executable, agent_config.__file__, kind, str(self.file), "{}"],
                                    capture_output=True, text=True, timeout=3)
            self.assertEqual(result.returncode, 1)
            self.assertEqual(result.stdout, "")
            self.assertNotIn("SYNTHETIC_PRIVATE_VALUE", result.stderr)
            self.assertNotIn("Traceback", result.stderr)


class SSHPolicy(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="nixi-ssh-policy-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.sshd = os.environ.get("NIXI_TEST_SSHD") or shutil.which("sshd") or "/usr/sbin/sshd"
        self.config = self.root / "sshd_config"
        self.script = (ROOT / "runtime/hey/ssh-policy.sh").read_text().replace(
            "/run/current-system/sw/bin/sshd", self.sshd).replace(
            "/etc/ssh/sshd_config", str(self.config)).replace("$(id -un)", "alice")

    def probe(self, connection="192.0.2.10 54321 192.0.2.20 22"):
        return subprocess.run(["sh", "-c", self.script],
                              env=os.environ | {"SSH_CONNECTION": connection},
                              capture_output=True, text=True, timeout=5)

    def test_global_match_and_include_policy_without_private_keys(self):
        included = self.root / "included.conf"
        included.write_text("Match Address 192.0.2.0/24 LocalPort 22\n  PasswordAuthentication yes\n")
        for extra, expected in [("", "no"),
                                ("Match User alice\n  PasswordAuthentication yes\n", "yes"),
                                (f"Include {included}\n", "yes")]:
            self.config.write_text("UseDNS no\nHostKey /nonexistent-synthetic-host-key\nPasswordAuthentication no\n" + extra)
            result = self.probe()
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), expected)

    def test_ambiguous_unreadable_and_invalid_policy_fail_closed(self):
        for content in ("UseDNS yes\nPasswordAuthentication no\n", "UnknownOption SYNTHETIC_PRIVATE_VALUE\n"):
            self.config.write_text(content)
            result = self.probe()
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, "")
            self.assertNotIn("SYNTHETIC_PRIVATE_VALUE", result.stderr)
        self.config.unlink()
        self.assertNotEqual(self.probe().returncode, 0)
        for connection in ("", "192.0.2.1 22", "192.0.2.1,user=root 20 192.0.2.2 22"):
            self.assertNotEqual(self.probe(connection).returncode, 0)


if __name__ == "__main__":
    unittest.main()
