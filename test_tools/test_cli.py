#!/usr/bin/env python3
"""Test-only CLI regressions. All mutable state belongs to TemporaryDirectory."""
import os
import json
import plistlib
import re
from pathlib import Path
import select
import shlex
import shutil
import subprocess
import tempfile
import time
import unittest
import sys

ROOT = Path(__file__).resolve().parents[1]
HEY = ROOT / "bin/hey"


class ConsumerCLI(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="nixi-cli-")
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        self.consumer = self.root / "consumer"
        self.consumer.mkdir()
        (self.consumer / "flake.nix").write_text("{ outputs = _: {}; }\n")
        self.env = {key: value for key, value in os.environ.items()
                    if key not in {"HEYENV", "DOTFILES", "DOTFILES_BIN", "HEY_THEME",
                                   "HEYDRYRUN", "TMUX", "TMUX_PANE", "TMUX_HOME"}
                    and not key.startswith("XDG_")}
        self.env.update(DOTFILES_HOME=str(self.consumer), HEY_HOST="laptop", HEY_USER="alice")
        for name in ("BIN", "DATA", "CONFIG", "CACHE", "STATE"):
            self.env[f"XDG_{name}_HOME"] = str(self.root / name.lower())
        self.env["XDG_RUNTIME_DIR"] = str(self.root / "runtime")

    def run_hey(self, *args, cwd=None):
        return subprocess.run([str(HEY), *args], cwd=cwd or self.consumer,
                              env=self.env, text=True, capture_output=True, timeout=30)

    def run_hey_bytes(self, *args):
        return subprocess.run([str(HEY), *args], cwd=self.consumer, env=self.env,
                              capture_output=True, timeout=30)

    def mock_command(self, name, body):
        directory = self.root / "mock-bin"
        directory.mkdir(exist_ok=True)
        self.env["DOTFILES_BIN"] = str(directory)
        executable = directory / name
        executable.write_text(f"#!{sys.executable}\n" + body)
        executable.chmod(0o755)
        return directory

    def isolate_nix(self):
        self.env["DOTFILES_HOME"] = str(self.consumer.resolve())
        self.env["NIX_REMOTE"] = str(self.root.resolve() / "nix-store")
        self.env["NIX_CONFIG"] = "experimental-features = nix-command flakes\n"

    def install_hook(self, event, body):
        self.mock_command("fixture-hook", body)
        directory = self.root / f"data/hey/hooks.d/{event}.d"
        directory.mkdir(parents=True, exist_ok=True)
        target = directory / "50-fixture"
        (self.root / "mock-bin/fixture-hook").replace(target)
        return target

    def isolate_home(self):
        home = self.root / "home"
        home.mkdir(exist_ok=True)
        self.env["HOME"] = str(home)
        self.env["ZDOTDIR"] = str(home)
        return home

    def test_external_dispatch_preserves_status_arguments_and_dry_runs(self):
        self.isolate_home()
        log = self.root / "dispatched-argv"
        directory = self.mock_command("fixture-task", f'''import json, sys
from pathlib import Path
Path({str(log)!r}).write_text(json.dumps(sys.argv[1:]))
sys.exit(23)
''')
        host = self.consumer / "hosts/laptop/bin"
        host.mkdir(parents=True)
        (host / "fixture-task").symlink_to(directory / "fixture-task")
        arguments = ["two words", "$(printf EXPANDED)", "quote'\"", "a;b"]
        for command in [("exec", "fixture-task"), ("host", "fixture-task"),
                        (".fixture-task",), (str(directory / "fixture-task"),)]:
            with self.subTest(command=command):
                result = self.run_hey(*command, *arguments)
                self.assertEqual(result.returncode, 23, result.stderr)
                self.assertEqual(json.loads(log.read_text()), arguments)
                log.unlink()
                result = self.run_hey("-!", *command, *arguments)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("DRYRUN:", result.stdout)
                self.assertFalse(log.exists())
                self.env["HEYDRYRUN"] = "1"
                try:
                    result = self.run_hey(*command, *arguments)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertFalse(log.exists())
                finally:
                    self.env.pop("HEYDRYRUN")

    def test_hook_priorities_do_not_depend_on_creation_order(self):
        self.isolate_home()
        log = self.root / "hook-order"
        directory = self.root / "data/hey/hooks.d/review-order.d"
        directory.mkdir(parents=True)
        names = ["90-last", "50-middle", "10-first"]
        for name in names:
            hook = directory / name
            hook.write_text(f"#!{sys.executable}\nfrom pathlib import Path\n"
                            f"with Path({str(log)!r}).open('a') as output: output.write({name!r} + '\\n')\n")
            hook.chmod(0o755)
        result = self.run_hey("hook", "review-order")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(log.read_text().splitlines(), sorted(names))

    def test_reload_cleanup_preserves_failure_and_dry_run(self):
        self.isolate_home()
        real_janet = shutil.which("janet")
        log = self.root / "cleanup"
        self.mock_command("janet", f'''import os, sys
from pathlib import Path
if "clean" in sys.argv:
    Path({str(log)!r}).touch()
    sys.exit(37)
os.execv({real_janet!r}, [{real_janet!r}, *sys.argv[1:]])
''')
        for target in ("cache", "k9s"):
            result = self.run_hey("reload", target)
            self.assertEqual(result.returncode, 37, result.stderr)
            self.assertNotIn("Done!", result.stdout)
            self.assertTrue(log.exists())
            log.unlink()
            result = self.run_hey("-!", "reload", target)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(log.exists())

    def configure_eks(self, **metadata):
        self.isolate_home()
        config = self.root / "config/hey/aws.json"
        config.parent.mkdir(parents=True, exist_ok=True)
        defaults = {"samlEnabled": False, "eksEnabled": True, "eksClusters": {}}
        defaults.update(metadata)
        config.write_text(json.dumps({"awscli2": defaults}))
        return config

    def test_option_parser_validates_before_running_command_bodies(self):
        self.isolate_home()
        log = self.root / "external-command"
        for command in ("ssh", "nix", "sudo", "utmctl", "darwin-rebuild", "nixos-rebuild"):
            self.mock_command(command, f"from pathlib import Path\nPath({str(log)!r}).touch()\n")
        for args in (
                ("utm", "cleanup-generations", "review", "--keep-generations"),
                ("utm", "update", "review", "--keep-generations"),
                ("utm", "update", "review", "--keep-generations", "--force"),
                ("utm", "update", "review", "--wait"),
                ("sync", "build", "--host"),
                ("sync", "build", "--flake"),
                ("sync", "build", "--flake", "--host", "review")):
            for prefix in ((), ("-!",)):
                with self.subTest(args=args, dry_run=bool(prefix)):
                    result = self.run_hey(*prefix, *args)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("requires 1 value", result.stderr)
                    self.assertNotIn("DRYRUN", result.stdout)
                    self.assertFalse(log.exists())

    def test_checkout_launcher_ignores_stale_installed_runtime(self):
        self.isolate_home()
        stale = self.root / "old-installed-runtime"
        (stale / "hey").mkdir(parents=True)
        (stale / "hey/init.janet").write_text('(error "stale runtime selected")\n')
        # Janet gives its system path precedence over JANET_PATH entries.
        # A trailing installed runtime must not override this launcher's code.
        self.env["JANET_PATH"] = self.env.get("JANET_PATH", "") + os.pathsep + str(stale)
        for args in (("--help",), ("swap", "--list"), ("-!", "sync", "build")):
            with self.subTest(args=args):
                result = self.run_hey(*args)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotIn("stale runtime selected", result.stdout + result.stderr)
        self.assertIn("DRYRUN:", result.stdout)

    def test_option_parser_schema_and_forwarding(self):
        self.isolate_home()
        self.env["JANET_PATH"] = ":".join([str(ROOT / "runtime"), self.env.get("JANET_PATH", "")])
        program = '''(import hey/cmd)
(def parse (cmd/cmdfn [a [-a {:default false}] b [-b]
                      number [--number n {:type :number}]
                      defaulted [--defaulted n {:type :number :default 7}]
                      pair [--pair x y]
                      tags [--tag tag {:multiple true}]
                      &args item & rest all]
             [a b number defaulted pair tags item rest all]))
(assert (= [false nil nil 7 nil nil nil [] []] (parse)))
(assert (= ["-a" "-b" -2.5 0 nil nil "-12" ["--unknown"]
            ["-ab" "--number" "-2.5" "--defaulted" "0" "-12" "--unknown"]]
           (parse "-ab" "--number" "-2.5" "--defaulted" "0" "-12" "--unknown")))
(assert (= [false nil 2 7 ["one" "two"] ["x" "y"] nil []
            ["--number" "1" "--number" "2" "--pair" "one" "two" "--tag" "x" "--tag" "y"]]
           (parse "--number" "1" "--number" "2" "--pair" "one" "two" "--tag" "x" "--tag" "y")))
(assert (= [false nil nil 7 nil nil "--number" ["-ab"] ["--" "--number" "-ab"]]
           (parse "--" "--number" "-ab")))
'''
        result = subprocess.run(["janet", "-e", program], cwd=self.consumer, env=self.env,
                                text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        for invocation in ('(parse "--pair")', '(parse "--pair" "one")',
                           '(parse "--number" "--")', '(parse "--number" "invalid")'):
            result = subprocess.run(["janet", "-e", program + invocation], cwd=self.consumer,
                                    env=self.env, text=True, capture_output=True, timeout=10)
            self.assertNotEqual(result.returncode, 0, invocation)
            self.assertRegex(result.stderr, "requires|expects a number")

    def test_eks_login_selects_provider_and_rejects_unknown_or_ambiguous_names(self):
        log = self.root / "login-calls"
        for command in ("aws", "saml2aws"):
            self.mock_command(command, f'''import json, sys
from pathlib import Path
Path({str(log)!r}).write_text(json.dumps([Path(sys.argv[0]).name, *sys.argv[1:]]))
''')
        self.configure_eks(ssoProfiles=["work"], samlEnabled=True, samlAccounts=["legacy"])
        for name, expected in [
                ("work", ["aws", "sso", "login", "--profile", "work"]),
                ("legacy", ["saml2aws", "login", "-a", "legacy"])]:
            result = self.run_hey("eks", "login", name)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(log.read_text()), expected)
            log.unlink()
        for args in [("unknown",), ()]:
            result = self.run_hey("eks", "login", *args)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(log.exists())
        self.configure_eks(ssoProfiles=["work"], samlEnabled=True, samlAccounts=["work"])
        result = self.run_hey("eks", "login", "work")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("both SAML and SSO", result.stderr)
        self.assertFalse(log.exists())
        self.configure_eks(ssoProfiles=["work"], samlEnabled=False, samlAccounts=["dormant"])
        result = self.run_hey("eks", "login")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(log.read_text()), ["aws", "sso", "login", "--profile", "work"])

    def test_eks_saml_dry_run_never_opens_secrets(self):
        log = self.root / "login-called"
        self.mock_command("saml2aws", f"from pathlib import Path\nPath({str(log)!r}).touch()\n")
        fifo = self.root / "secret-fifo"
        os.mkfifo(fifo)
        for secret in (self.root / "missing", fifo):
            self.configure_eks(samlEnabled=True, samlAccounts=["legacy"],
                               samlAccountDetails={"legacy": {"usernameFile": str(secret),
                                                              "passwordFile": str(secret)}})
            result = self.run_hey("-!", "eks", "login", "legacy")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("saml2aws login -a legacy --skip-prompt", result.stdout)
            self.assertFalse(log.exists())

    def test_eks_saml_rejects_special_and_oversized_credentials_before_login(self):
        log = self.root / "login-called"
        self.mock_command("saml2aws", f"from pathlib import Path\nPath({str(log)!r}).touch()\n")
        fifo = self.root / "credential-fifo"
        os.mkfifo(fifo)
        large = self.root / "large"
        large.write_bytes(b"x" * 65537)
        for source in (fifo, large, self.root, self.root / "missing"):
            self.configure_eks(samlEnabled=True, samlAccounts=["fixture"], samlAccountDetails={
                "fixture": {"passwordFile": str(source), "passwordFileFormat": "password"}})
            result = self.run_hey("eks", "login", "fixture")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("regular file of at most 64 KiB", result.stderr)
            self.assertFalse(log.exists())

    def test_eks_saml_interactive_retry_discards_failed_password(self):
        log = self.root / "login-attempts"
        username = self.root / "username"
        password = self.root / "password"
        username.write_text("fixture-user\n")
        password.write_text("fixture-password\n")
        self.configure_eks(samlEnabled=True, samlAccounts=["legacy"],
                           samlAccountDetails={"legacy": {"usernameFile": str(username),
                                                          "passwordFile": str(password)}})
        self.mock_command("saml2aws", f'''import os, sys
from pathlib import Path
assert os.getenv("SAML2AWS_USERNAME") == "fixture-user"
with Path({str(log)!r}).open("a") as output:
    output.write("attempt\\n")
if "--skip-prompt" in sys.argv:
    assert os.getenv("SAML2AWS_PASSWORD") == "fixture-password"
    sys.exit(9)
assert not os.getenv("SAML2AWS_PASSWORD")
''')
        result = self.run_hey("eks", "login", "legacy")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(log.read_text().splitlines(), ["attempt", "attempt"])
        self.assertNotIn("fixture-password", result.stdout + result.stderr)

    def test_eks_saml_credential_formats_preserve_values_and_reject_malformed_input(self):
        self.isolate_home()
        username = self.root / "username"
        password = self.root / "password"
        username.write_bytes(b"fixture-user\r\n")
        self.mock_command("saml2aws", '''import os
assert os.getenv("SAML2AWS_PASSWORD") == " fixture-password "
assert os.getenv("SAML2AWS_USERNAME") == os.getenv("EXPECTED_SAML_USER")
print("fixture-login-ok")
''')
        for separate, format, content, expected_user in [
            (True, "password", b" fixture-password \n", "fixture-user"),
            (True, "password", b" fixture-password \r\n", "fixture-user"),
            (False, "password", b" fixture-password ", None),
            (False, "username-password", b"fixture-user\n fixture-password \n", "fixture-user"),
            (False, "username-password", b"fixture-user\r\n fixture-password \r\n", "fixture-user"),
            (False, None, b"fixture-user\n fixture-password \n", "fixture-user"),
        ]:
            with self.subTest(separate=separate, format=format, content=content):
                password.write_bytes(content)
                self.env.pop("EXPECTED_SAML_USER", None)
                if expected_user is not None:
                    self.env["EXPECTED_SAML_USER"] = expected_user
                self.configure_eks(samlEnabled=True, samlAccounts=["legacy"],
                                   samlAccountDetails={"legacy": {
                                       "usernameFile": str(username) if separate else None,
                                       "passwordFile": str(password), "passwordFileFormat": format}})
                result = self.run_hey("eks", "login", "legacy")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("fixture-login-ok", result.stdout)
                self.assertNotIn("fixture-password", result.stdout + result.stderr)
        for format, content in [("password", b""), ("password", b"one\ntwo\n"),
                                ("password", b"fixture\0secret"), ("password", b"fixture\rsecret"),
                                ("username-password", b"only-one-line"),
                                ("username-password", b"user\npassword\nextra"),
                                ("unknown", b"fixture")]:
            password.write_bytes(content)
            self.configure_eks(samlEnabled=True, samlAccounts=["legacy"],
                               samlAccountDetails={"legacy": {"passwordFile": str(password),
                                                              "passwordFileFormat": format}})
            result = self.run_hey("eks", "login", "legacy")
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn("fixture-login-ok", result.stdout)

    def test_eks_nullable_metadata_and_invalid_types(self):
        log = self.root / "login-called"
        self.mock_command("saml2aws", f"from pathlib import Path\nPath({str(log)!r}).touch()\n")
        self.configure_eks(samlEnabled=True, samlAccounts=["legacy"], samlAccountDetails={
            "legacy": {"usernameFile": None, "passwordFile": None, "awsProfile": None}})
        result = self.run_hey("eks", "login", "legacy")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(log.exists())
        log.unlink()
        for field in ("usernameFile", "passwordFile", "passwordFileFormat", "awsProfile"):
            for invalid in (False, 42, [], {}):
                self.configure_eks(samlEnabled=True, samlAccounts=["legacy"],
                                   samlAccountDetails={"legacy": {field: invalid}})
                result = self.run_hey("eks", "login", "legacy")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(f"{field} must be a string or null", result.stderr)
                self.assertFalse(log.exists())

    def test_eks_rejects_cluster_path_traversal_before_commands(self):
        log = self.root / "aws-called"
        self.mock_command("aws", f"from pathlib import Path\nPath({str(log)!r}).touch()\n")
        for key in ("../../../outside", ".", "..", "nested/cluster", "/absolute", "bad\\name"):
            for prefix in ((), ("-!",)):
                self.configure_eks(eksClusters={key: {"name": "review", "profile": "work"}})
                result = self.run_hey(*prefix, "eks", "kubeconfig", key)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("EKS cluster keys", result.stderr)
                self.assertFalse(log.exists())
                self.assertFalse((self.root / "config/hey/eks/kubeconfigs").exists())

    def test_eks_metadata_versions_and_required_fields(self):
        for version in (None, 1):
            metadata = {} if version is None else {"schemaVersion": version}
            self.configure_eks(**metadata)
            self.assertEqual(self.run_hey("eks", "list").returncode, 0)
        for version in (0, 2, True, "1"):
            self.configure_eks(schemaVersion=version)
            result = self.run_hey("eks", "list")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("schemaVersion", result.stderr)
        for field in ("name", "profile"):
            cluster = {"name": "review", "profile": "work", field: ""}
            self.configure_eks(eksClusters={"review": cluster})
            result = self.run_hey("eks", "list")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("requires nonempty", result.stderr)

    def test_eks_context_creation_matches_selection_without_explicit_alias(self):
        self.mock_command("aws", '''import json, sys
from pathlib import Path
args = sys.argv[1:]
context = args[args.index("--alias") + 1] if "--alias" in args else "arn:aws:eks:us-east-1:111122223333:cluster/review"
Path(args[args.index("--kubeconfig") + 1]).write_text(json.dumps({"context": context}))
''')
        self.mock_command("kubectl", '''import json, sys
from pathlib import Path
args = sys.argv[1:]
context = json.loads(Path(args[args.index("--kubeconfig") + 1]).read_text())["context"]
assert args[-1] == context, (args, context)
''')
        for alias in (None, "", "custom-context"):
            self.configure_eks(eksClusters={"review": {"name": "review", "profile": "work", "kubeContext": alias}})
            result = self.run_hey("eks", "use", "review")
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_vm_wait_bounds_stalled_listing(self):
        self.isolate_home()
        self.mock_command("utmctl", "import time\ntime.sleep(1.5)\nprint('UUID STATUS NAME')\n")
        env = self.env | {"PATH": self.env["DOTFILES_BIN"] + os.pathsep + self.env["PATH"]}
        env["JANET_PATH"] = str(ROOT / "vendor/janet") + os.pathsep + env.get("JANET_PATH", "") + os.pathsep + str(ROOT / "runtime")
        start = time.monotonic()
        result = subprocess.run(["janet", "-m", str(ROOT / "runtime"), "-e",
                                 '(use hey/vm) (vm/wait-for "fixture" true 0.1)'],
                                env=env, capture_output=True, text=True, timeout=3)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("timed out", result.stderr.lower())
        self.assertLess(time.monotonic() - start, 1.2)

    @unittest.skipUnless(os.getenv("NIXI_EKS_FIXTURES"), "Nix-generated EKS fixtures supplied by cli-behavior check")
    def test_eks_nix_generated_metadata_and_sudo_policy(self):
        fixtures = json.loads(Path(os.environ["NIXI_EKS_FIXTURES"]).read_text())
        log = self.root / "login-calls"
        username, password = self.root / "username", self.root / "password"
        username.write_text("fixture-user\n")
        self.mock_command("saml2aws", f'''import json, os, sys
from pathlib import Path
with Path({str(log)!r}).open("a") as output:
    output.write(json.dumps(sys.argv[1:]) + "\\n")
if "--skip-prompt" in sys.argv:
    assert os.getenv("SAML2AWS_USERNAME") == "fixture-user"
    assert os.getenv("SAML2AWS_PASSWORD") == "fixture-password"
''')
        for platform, metadata in fixtures["metadata"].items():
            with self.subTest(platform=platform):
                details = metadata["samlAccountDetails"]
                self.assertIsNone(details["passwordOnly"]["usernameFile"])
                self.assertEqual(details["passwordOnly"]["passwordFileFormat"], "username-password")
                self.assertIsNone(details["passwordOnly"]["awsProfile"])
                self.assertIsNone(details["interactive"]["passwordFile"])
                # Replace only non-null secret paths, keeping the actual Nix
                # schema, missing/nullable fields and provider mappings intact.
                for account in details.values():
                    if account["usernameFile"] is not None:
                        account["usernameFile"] = str(username)
                    if account["passwordFile"] is not None:
                        account["passwordFile"] = str(password)
                self.configure_eks(**metadata)
                for account in ("passwordOnly", "split", "interactive"):
                    password.write_text("fixture-user\nfixture-password\n" if account == "passwordOnly"
                                        else "fixture-password\n")
                    result = self.run_hey("eks", "login", account)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(json.loads(log.read_text().splitlines()[-1]),
                                     ["login", "-a", account] + ([] if account == "interactive" else ["--skip-prompt"]))
                    self.assertNotIn("fixture-password", result.stdout + result.stderr)
                password.unlink()
                for command in ("aws", "kubectl", "k9s", "stern"):
                    self.mock_command(command, "pass\n")
                # A null awsProfile must fall back to the SAML account name.
                result = self.run_hey("-!", "eks", "doctor", "passwordOnly")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("validate declared SAML credential files", result.stdout)
                result = self.run_hey("-!", "eks", "login", "passwordOnly")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("--skip-prompt", result.stdout)
        calls = self.root / "sudo-calls"
        self.mock_command("sudo", f'''import json, shlex, sys
from pathlib import Path
rules = json.loads(Path({os.environ['NIXI_EKS_FIXTURES']!r}).read_text())["sudoCommands"]
assert sys.argv[1] == "-n"
assert sys.argv[2:] in [shlex.split(rule["command"]) for rule in rules if rule["options"] == ["NOPASSWD"]]
with Path({str(calls)!r}).open("a") as output: output.write(json.dumps(sys.argv[2:]) + "\\n")
''')
        self.mock_command("systemctl", 'import sys\nassert sys.argv[1:] == ["is-active", "--quiet", "openvpn-fixture.service"]\n')
        self.configure_eks(eksClusters={"vpn": fixtures["vpnCluster"]})
        result = self.run_hey("eks", "vpn", "restart", "vpn")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([json.loads(line)[1] for line in calls.read_text().splitlines()], ["reset-failed", "restart"])

    def mock_eks_probes(self):
        log = self.root / "probe-calls"
        for command in ("aws", "kubectl", "k9s", "stern", "systemctl", "sudo"):
            self.mock_command(command, f'''import json, os, sys
from pathlib import Path
name = Path(sys.argv[0]).name
with Path({str(log)!r}).open("a") as output:
    output.write(json.dumps([name, *sys.argv[1:]]) + "\\n")
if name == "sudo" or "update-kubeconfig" in sys.argv:
    sys.exit(99)
if name == "systemctl":
    assert sys.argv[1:4] == ["is-active", "--quiet", "openvpn-fixture.service"]
    sys.exit(int(os.getenv("FIXTURE_VPN_STATUS", "0")))
if name == "aws" and "get-caller-identity" in sys.argv:
    print('{{"Account":"fixture"}}')
''')
        return log

    def test_eks_diagnostics_inspect_existing_state_without_initializing(self):
        log = self.mock_eks_probes()
        cluster = {"name": "review", "profile": "work", "bastion": "laptop",
                   "vpnService": "openvpn-fixture.service"}
        self.configure_eks(ssoProfiles=["work"], eksClusters={"review": cluster})
        kubeconfig = self.root / "config/hey/eks/kubeconfigs/review.yaml"
        for command in ("status", "doctor"):
            for existing, vpn_status in [(False, "0"), (True, "0"), (True, "3")]:
                with self.subTest(command=command, existing=existing, vpn_status=vpn_status):
                    if existing:
                        kubeconfig.parent.mkdir(parents=True, exist_ok=True)
                        kubeconfig.write_text("fixture kubeconfig\n")
                    else:
                        kubeconfig.unlink(missing_ok=True)
                    self.env["FIXTURE_VPN_STATUS"] = vpn_status
                    result = self.run_hey("eks", command, "review")
                    self.assertEqual(result.returncode, 0 if existing and vpn_status == "0" else 1,
                                     result.stdout + result.stderr)
                    self.assertEqual(kubeconfig.exists(), existing)
                    if existing:
                        self.assertEqual(kubeconfig.read_text(), "fixture kubeconfig\n")
                    else:
                        self.assertIn("hey eks kubeconfig review", result.stderr)
                    calls = [json.loads(line) for line in log.read_text().splitlines()]
                    self.assertIn(["systemctl", "is-active", "--quiet", "openvpn-fixture.service"], calls)
                    self.assertFalse(any(call[0] == "sudo" or "update-kubeconfig" in call for call in calls))
                    self.assertEqual(any(call[0] == "kubectl" for call in calls), existing)
                    log.unlink()
            result = self.run_hey("-!", "eks", command, "review")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn("update-kubeconfig", result.stdout)
            self.assertNotIn("reset-failed", result.stdout)
            self.assertFalse(log.exists())

    def test_eks_doctor_only_requires_enabled_authentication_tools(self):
        self.mock_eks_probes()
        # command discovery must not accidentally find tools on the developer's PATH.
        directory = self.root / "mock-bin"
        for command in ("janet", "dirname"):
            (directory / command).symlink_to(shutil.which(command))
        self.env["PATH"] = str(directory)
        for metadata in [
                {"ssoProfiles": ["work"]},
                {"samlAccounts": ["dormant"], "samlEnabled": False},
                {"eksEnabled": False}]:
            self.configure_eks(**metadata)
            result = self.run_hey("eks", "doctor")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn("saml2aws", result.stdout + result.stderr)
            if metadata.get("eksEnabled") is False:
                self.assertNotIn("kubectl", result.stdout)
        cluster = {"name": "review", "profile": "mapped-profile"}
        self.configure_eks(samlEnabled=True, samlAccounts=["legacy"],
                           samlAccountDetails={"legacy": {"awsProfile": "mapped-profile"}},
                           eksClusters={"review": cluster})
        result = self.run_hey("-!", "eks", "doctor", "review")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("saml2aws is available", result.stderr)
        self.mock_command("saml2aws", "pass\n")
        result = self.run_hey("-!", "eks", "doctor", "review")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_eks_doctor_uses_login_credential_limits_and_format(self):
        self.mock_eks_probes()
        self.mock_command("saml2aws", "raise AssertionError('doctor must not log in')\n")
        password = self.root / "password"
        self.configure_eks(samlEnabled=True, samlAccounts=["fixture"],
                           samlAccountDetails={"fixture": {"passwordFile": str(password),
                                                          "passwordFileFormat": "password"}},
                           eksClusters={"review": {"name": "review", "profile": "fixture"}})
        kube = self.root / "config/hey/eks/kubeconfigs/review.yaml"
        kube.parent.mkdir(parents=True)
        kube.write_text("fixture kubeconfig\n")
        for data, valid in [(b'x' * 65537, False), (b'\xffSYNTHETIC_PRIVATE_VALUE', False),
                            (b'one\ntwo\n', False), (b'  meaningful spaces  \r\n', True)]:
            password.write_bytes(data)
            result = self.run_hey("eks", "doctor", "review")
            self.assertEqual(result.returncode == 0, valid, result.stdout + result.stderr)
            self.assertNotIn("SYNTHETIC_PRIVATE_VALUE", result.stdout + result.stderr)
            self.assertIn("login input contract" if valid else "failed validation", result.stderr)
        password.unlink()
        os.mkfifo(password)
        result = self.run_hey("eks", "doctor", "review")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("failed validation", result.stderr)
        result = self.run_hey("-!", "eks", "doctor", "review")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("DRYRUN: validate declared SAML", result.stdout)

    def test_eks_bastion_diagnostics_do_not_start_vpn(self):
        self.configure_eks(eksClusters={"review": {
            "name": "review", "profile": "work", "bastion": "fixture",
            "vpnService": "openvpn-fixture.service"}})
        self.mock_command("utmctl", 'print("198.51.100.2")\n')
        log = self.root / "ssh-calls"
        self.mock_command("ssh", f'''import json, sys
from pathlib import Path
with Path({str(log)!r}).open("a") as output:
    output.write(json.dumps(sys.argv[1:]) + "\\n")
if sys.argv[-1] != "true":
    sys.exit(23)
''')
        for command in ("status", "doctor"):
            result = self.run_hey("eks", command, "review")
            self.assertEqual(result.returncode, 23, result.stderr)
            calls = [json.loads(line) for line in log.read_text().splitlines()]
            self.assertTrue(any(shlex.split(call[-1]) == ["hey", "eks", command, "review"] for call in calls))
            self.assertFalse(any("systemctl" in call[-1] for call in calls))
            log.unlink()
            result = self.run_hey("-!", "eks", command, "review")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn("systemctl", result.stdout)
            self.assertFalse(log.exists())
        result = self.run_hey("-!", "eks", "kubeconfig", "review")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("systemctl start", result.stdout)

    def test_eks_bastion_shell_requests_a_terminal(self):
        self.configure_eks(eksClusters={"review": {
            "name": "review", "profile": "work", "bastion": "fixture"}})
        self.mock_command("utmctl", 'print("198.51.100.2")\n')
        log = self.root / "ssh-calls"
        self.mock_command("ssh", f'''import json, sys
from pathlib import Path
with Path({str(log)!r}).open("a") as output: output.write(json.dumps(sys.argv[1:]) + "\\n")
''')
        for command, terminal in (("shell", True), ("open", True), ("status", False), ("kubeconfig", False)):
            result = self.run_hey("eks", command, "review")
            self.assertEqual(result.returncode, 0, result.stderr)
            calls = [json.loads(line) for line in log.read_text().splitlines()]
            routed = [call for call in calls if shlex.split(call[-1]) == ["hey", "eks", command, "review"]]
            for call in calls:
                self.assertIn("StrictHostKeyChecking=yes", call)
                self.assertIn("BatchMode=yes", call)
                self.assertNotIn("StrictHostKeyChecking=accept-new", call)
            self.assertEqual(len(routed), 1)
            self.assertEqual("-t" in routed[0], terminal)
            log.unlink()
            result = self.run_hey("-!", "eks", command, "review")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual("DRYRUN: ssh -t " in result.stdout, terminal)
            self.assertFalse(log.exists())

    def test_process_capture_deadline_is_bounded_and_does_not_leak(self):
        self.isolate_home()
        self.env["JANET_PATH"] = ":".join([str(ROOT / "runtime"), str(ROOT / "vendor/janet"),
                                          self.env.get("JANET_PATH", "")])
        sleeper = self.root / "sleeper"
        pid_file = self.root / "sleeper-pid"
        sleeper.write_text(f"#!{shutil.which('sh')}\n"
                           f"printf '%s' \"$$\" > {shlex.quote(str(pid_file))}\n"
                           f"exec {shlex.quote(shutil.which('sleep'))} 10\n")
        sleeper.chmod(0o755)
        program = f'''(import hey/process)
(def timed (process/capture [{json.dumps(str(sleeper))}] 1))
(assert (= 124 (timed :status)))
(assert (timed :timeout))
(def normal (process/capture [{json.dumps(sys.executable)} "-c"
                              "import sys, time; time.sleep(0.1); print('out'); print('err', file=sys.stderr); sys.exit(7)"] 1))
(assert (= 7 (normal :status)))
(assert (= "out" (normal :out)))
(assert (= "err" (normal :err)))
(assert (not (normal :timeout)))
(each stream ["stdout" "stderr"]
  (def overflow (process/capture [{json.dumps(sys.executable)} "-c"
    (string "import sys; sys." stream ".write('x' * 70000)")] 1 65536))
  (assert (= 125 (overflow :status)))
  (assert (= "" (overflow :out)))
  (assert (string/find "captured output exceeded" (overflow :err))))
(def exact (process/capture [{json.dumps(sys.executable)} "-c"
  "import sys; sys.stdout.write('x' * 65536)"] 1 65536))
(assert (= 0 (exact :status)))
(assert (= 65536 (length (exact :out))))
(var failed false)
(try (process/capture ["/nonexistent-nixi-probe"] 1) ([err] (set failed true)))
(assert failed)
'''
        result = subprocess.run(["janet", "-e", program], cwd=self.consumer, env=self.env,
                                capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        with self.assertRaises(ProcessLookupError):
            os.kill(int(pid_file.read_text()), 0)

    def test_diagnostic_probe_rejects_invalid_deadlines(self):
        self.isolate_home()
        program = '''(import hey/process)
(each timeout [0 -1 math/inf math/nan "10"]
  (var rejected false)
  (try (process/probe ["/nonexistent-nixi-probe"] timeout)
    ([err fib] (set rejected (= err "Probe timeout must be a finite positive number"))))
  (assert rejected))
'''
        env = self.env | {"JANET_PATH": self.env.get("JANET_PATH", "") + os.pathsep + str(ROOT / "runtime")}
        result = subprocess.run(["janet", "-e", program], env=env, capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_tmux_and_direnv_doctors_bound_and_reap_stalled_probes(self):
        self.isolate_home()
        pidfile = self.root / "diagnostic-pid"
        for command in ("tmux", "direnv"):
            with self.subTest(command=command):
                self.mock_command(command, f'''import os, time
from pathlib import Path
Path({str(pidfile)!r}).write_text(str(os.getpid()))
time.sleep(60)
''')
                dry = self.run_hey("-!", command, "doctor")
                self.assertEqual(dry.returncode, 0, dry.stderr)
                self.assertFalse(pidfile.exists())
                started = time.monotonic()
                result = self.run_hey(command, "doctor")
                self.assertLess(time.monotonic() - started, 18)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("timed out after 10 seconds", result.stdout + result.stderr)
                self.assertNotIn(command + " doctor passed", result.stdout)
                with self.assertRaises(ProcessLookupError):
                    os.kill(int(pidfile.read_text()), 0)
                pidfile.unlink()

    def test_tmux_and_direnv_doctors_reject_output_overflow(self):
        self.isolate_home()
        for command in ("tmux", "direnv"):
            self.mock_command(command, "import sys\nsys.stdout.write('x' * (9 * 1024 * 1024))\n")
            result = self.run_hey(command, "doctor")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("captured output exceeded", result.stdout + result.stderr)
            self.assertNotIn(command + " doctor passed", result.stdout)

    def test_tmux_failed_probe_does_not_trigger_session_actions(self):
        self.isolate_home()
        log = self.root / "tmux-probes"
        self.mock_command("tmux", f'''import json, sys
from pathlib import Path
with Path({str(log)!r}).open("a") as output: output.write(json.dumps(sys.argv[1:]) + "\\n")
sys.stdout.write('x' * (9 * 1024 * 1024))
''')
        for args, expected in [(("project", "fixture", str(self.consumer)), "has-session"),
                               (("clean",), "list-sessions")]:
            result = self.run_hey("tmux", *args)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("captured output exceeded", result.stdout + result.stderr)
            calls = [json.loads(line) for line in log.read_text().splitlines()]
            self.assertEqual(len(calls), 1)
            self.assertEqual(calls[0][0], expected)
            log.unlink()

    def diagnostic_fixture(self):
        self.isolate_home()
        for command, output in (("hostname", "laptop"), ("uname", "Darwin"),
                                ("nix", "nix fixture"), ("kubectl", "fixture-context"),
                                ("darwin-rebuild", "")):
            self.mock_command(command, f"print({output!r})\n")
        directory = self.root / "mock-bin"
        for name in ("janet", "dirname"):
            (directory / name).symlink_to(shutil.which(name))
        (directory / "hey").symlink_to(HEY)
        metadata = self.root / "data/hey"
        metadata.mkdir(parents=True)
        (metadata / "path").write_text(str(directory))
        self.env.update(PATH=str(directory), HEY_NIX_USE_NOM="0")

    def test_diagnostics_never_print_nix_config(self):
        self.diagnostic_fixture()
        marker = "SYNTHETIC_PRIVATE_CONFIGURATION_MARKER"
        for config in (f"access-tokens = github.com={marker}\n",
                       f"store = local\nsubstituters = https://user:{marker}@cache.invalid\n",
                       f"unrecognized-setting = {marker}\n"):
            self.env["NIX_CONFIG"] = config
            for args in (("context",), ("sync", "--explain"), ("sync", "--explain", "-?"), ("doctor", "sync"),
                         ("doctor", "sync", "--quiet"), ("doctor", "sync", "--verbose")):
                result = self.run_hey(*args)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotIn(marker, result.stdout + result.stderr)
                self.assertNotIn("github.com=", result.stdout + result.stderr)

    def test_secret_doctor_scans_hidden_and_ignored_files_but_not_history(self):
        self.diagnostic_fixture()
        (self.root / "mock-bin/rg").symlink_to(shutil.which("rg"))
        self.env["HEY_DOCTOR_SECRET_PATHS"] = str(self.consumer)
        (self.consumer / ".gitignore").write_text(".envrc\nignored-secret\n")
        for name in (".git", ".direnv", "node_modules", "target"):
            folder = self.consumer / name
            folder.mkdir()
            (folder / "excluded").write_text("SOPS_AGE_KEY=SYNTHETIC_EXCLUDED\n")
        result = self.run_hey("doctor", "secrets")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("no inline secret markers found", result.stdout)
        for name in (".envrc", "ignored-secret"):
            secret = self.consumer / name
            secret.write_text("SOPS_AGE_KEY=SYNTHETIC_PRIVATE_VALUE\n")
            result = self.run_hey("doctor", "secrets")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("inline secret markers found", result.stderr)
            self.assertNotIn("SYNTHETIC_PRIVATE_VALUE", result.stdout + result.stderr)
            self.assertNotIn("SYNTHETIC_EXCLUDED", result.stdout + result.stderr)
            secret.unlink()

    def test_agent_doctor_parses_configuration_instead_of_matching_comments(self):
        self.diagnostic_fixture()
        self.mock_command("ps", "pass\n")
        directory = self.root / "data/hey/agents"
        directory.mkdir()
        codex = self.root / "home/.codex"
        codex.mkdir()
        (directory / "codex.json").write_text(json.dumps({
            "codexHome": str(codex), "mcpServers": ["fixture"], "plugins": []}))
        (self.root / "data/hey/capabilities.json").write_text(json.dumps({"version": 1, "groups": {"agents": {}}}))
        for content, status in [
            ('# [mcp_servers.fixture]\n', "missing"),
            ('[mcp_servers.fixture]\nenabled=false\n', "disabled"),
            ('[mcp_servers."fixture"]\ncommand="fixture"\n', "configured"),
            ('[mcp_servers.fixture]\nenabled="no"\n', "malformed"),
            ('[SYNTHETIC_PRIVATE_VALUE', "could not be validated"),
        ]:
            (codex / "config.toml").write_text(content)
            result = self.run_hey("doctor", "agents", "--verbose")
            self.assertEqual(result.returncode == 0, status == "configured", result.stdout + result.stderr)
            self.assertIn(status, result.stdout + result.stderr)
            self.assertNotIn("SYNTHETIC_PRIVATE_VALUE", result.stdout + result.stderr)
        (codex / "config.toml").unlink()
        result = self.run_hey("doctor", "agents")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("could not be validated", result.stderr)

    def test_secret_doctor_never_forwards_failed_scan_output(self):
        self.isolate_home()
        marker = "SYNTHETICREDACTIONVALUE"
        source = self.consumer / "manifest:with-colon.yaml"
        source.write_text("password: " + marker + "\n")
        rg_config = self.root / "rg.conf"
        rg_config.write_text("--no-messages\n--glob=!*.yaml\n")
        self.env.update(RIPGREP_CONFIG_PATH=str(rg_config), HEY_DOCTOR_SECRET_PATHS=str(self.consumer))
        result = self.run_hey("doctor", "secrets")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(source.name, result.stderr)
        self.assertNotIn(marker, result.stdout + result.stderr)
        self.env["HEY_DOCTOR_SECRET_PATHS"] += ":" + str(self.root / "missing-root")
        result = self.run_hey("doctor", "secrets")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn(marker, result.stdout + result.stderr)
        # A failed command may put arbitrary data on either stream. Do not rely
        # on a particular ripgrep version/error mode to keep stderr empty.
        for status, err, out in [(2, "", marker), (2, marker, marker), (0, "", marker),
                                 (0, "", '{"type":"unknown"}'), (0, "", '{"type":"summary"}')]:
            self.mock_command("rg", f'''import sys
assert "--no-config" in sys.argv and "--json" in sys.argv
print({out!r})
sys.stderr.write({err!r})
sys.exit({status})
''')
            result = self.run_hey("doctor", "secrets")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("scan failed", result.stderr)
            self.assertNotIn(marker, result.stdout + result.stderr)

    def test_codex_doctor_with_no_optional_integrations(self):
        self.diagnostic_fixture()
        self.mock_command("ps", "pass\n")
        directory = self.root / "data/hey/agents"
        directory.mkdir()
        codex = self.root / "home/.codex"
        codex.mkdir()
        (directory / "codex.json").write_text(json.dumps({
            "codexHome": str(codex), "plugins": [], "mcpServers": []}))
        (codex / "config.toml").write_text("# No plugins or MCP integrations\n")
        (self.root / "data/hey/capabilities.json").write_text(json.dumps({"version": 1, "groups": {"agents": {}}}))
        result = self.run_hey("doctor", "agents")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("agents doctor passed", result.stdout)

    def test_sync_doctor_accepts_missing_optional_nom(self):
        self.diagnostic_fixture()
        self.env["NIX_CONFIG"] = ""
        for selected in ("0", "1"):
            self.env["HEY_NIX_USE_NOM"] = selected
            result = self.run_hey("doctor", "sync")
            self.assertEqual(result.returncode, 0, result.stderr)
            if selected == "1":
                self.assertIn("Nix will run without it", result.stderr)

    def test_normal_sync_never_logs_nix_config_at_any_verbosity(self):
        self.diagnostic_fixture()
        marker = "SYNTHETIC_PRIVATE_CONFIGURATION_MARKER"
        self.env["NIX_CONFIG"] = f"access-tokens = github.com={marker}\n"
        for status in (0, 7):
            self.mock_command("nix", f"raise SystemExit({status})\n")
            for verbosity in ([], ["-?"], ["-??"], ["-???"]):
                for dry in ([], ["-!"]):
                    with self.subTest(status=status, verbosity=verbosity, dry=dry):
                        result = self.run_hey(*verbosity, *dry, "sync", "build", "--flake", str(self.consumer) + "#laptop")
                        self.assertEqual(result.returncode, 0 if dry else status, result.stderr)
                        self.assertNotIn(marker, result.stdout + result.stderr)
                        self.assertNotIn("github.com=", result.stdout + result.stderr)
                        if verbosity:
                            self.assertIn("<set; contents hidden>", result.stderr)

    def test_sync_plan_never_builds_activates_updates_locks_or_uses_nom(self):
        self.isolate_home()
        calls = self.root / "plan-argv"
        lock = self.consumer / "flake.lock"
        lock.write_text("synthetic lock must stay untouched")
        for command in ("sudo", "darwin-rebuild", "nixos-rebuild", "nom", "hey"):
            self.mock_command(command, "raise RuntimeError('mutation or unrelated command attempted')\n")
        self.mock_command("nix", f'''import json, os, sys
from pathlib import Path
assert "NIX_PATH" not in os.environ
Path({str(calls)!r}).write_text(json.dumps(sys.argv[1:]))
print("17 derivations will be built; 23 paths will be fetched (42 MiB download)", file=sys.stderr)
''')
        self.env.update(NIX_PATH="unused-path", HEY_NIX_USE_NOM="1")
        for platform, attr in (("Darwin", "darwinConfigurations.laptop.system"),
                               ("Linux", "nixosConfigurations.laptop.config.system.build.toplevel")):
            self.mock_command("uname", f"print({platform!r})\n")
            result = self.run_hey("sync", "plan", "--flake", str(self.consumer) + "#laptop")
            self.assertEqual(result.returncode, 0, result.stderr)
            argv = json.loads(calls.read_text())
            self.assertEqual(argv, ["build", "--dry-run", "--no-link", "--impure",
                "--no-write-lock-file", "--no-update-lock-file",
                "--option", "allow-import-from-derivation", "false",
                "--option", "accept-flake-config", "false", str(self.consumer) + "#" + attr])
            self.assertIn("17 derivations", result.stderr)
            calls.unlink()
            for prefix, extra in ((["-!"], []), ([], ["--explain"])):
                result = self.run_hey(*prefix, "sync", "plan", *extra)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("DRYRUN", result.stdout)
                self.assertFalse(calls.exists())
        for extra in (["--fast"], ["switch"], ["--option", "allow-import-from-derivation", "true"]):
            self.assertNotEqual(self.run_hey("sync", "plan", *extra).returncode, 0)
            self.assertFalse(calls.exists())
        self.mock_command("nix", "raise SystemExit(17)\n")
        self.assertEqual(self.run_hey("sync", "plan").returncode, 17)
        self.assertEqual(lock.read_text(), "synthetic lock must stay untouched")
        self.assertFalse((self.consumer / "result").exists())
        self.assertFalse((self.root / "runtime/profile-rm.lock").exists())

    def test_sync_plan_with_real_isolated_nix_refuses_evaluation_time_builds(self):
        self.isolate_home()
        self.isolate_nix()
        self.mock_command("uname", "print('Darwin')\n")
        marker = self.root / "builder-ran"
        lock = self.consumer / "flake.lock"
        lock.write_text(json.dumps({"version": 7, "root": "root", "nodes": {"root": {"inputs": {}}}}))
        before = lock.read_bytes()
        expression = '''{ outputs = _: let probe = builtins.derivation {
          name = "nixi-plan-fixture"; system = builtins.currentSystem;
          builder = "/bin/sh"; args = ["-c" "touch @MARKER@; echo should-not-build > $out"];
        }; in { darwinConfigurations.laptop.system = @TARGET@; }; }'''.replace("@MARKER@", str(marker))
        for target, succeeds in (("probe", True), ("builtins.seq (builtins.readFile probe) probe", False)):
            (self.consumer / "flake.nix").write_text(expression.replace("@TARGET@", target))
            result = self.run_hey("sync", "plan", "--flake", str(self.consumer) + "#laptop")
            self.assertEqual(result.returncode == 0, succeeds, result.stderr)
            self.assertFalse(marker.exists())
            self.assertFalse((self.consumer / "result").exists())
            self.assertEqual(lock.read_bytes(), before)

    def test_security_scan_is_explicit_dry_run_safe_and_preserves_status(self):
        self.isolate_home()
        target = "/nix/store/" + "0" * 32 + "-synthetic-system.drv"
        log = self.root / "scan-argv"
        self.mock_command("vulnix", f'''import json, sys
from pathlib import Path
Path({str(log)!r}).write_text(json.dumps(sys.argv[1:]))
raise SystemExit(2)
''')
        result = self.run_hey("-!", "security", "scan", target, "--json")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(log.exists())
        result = self.run_hey("security", "scan", target, "--json")
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(json.loads(log.read_text()), ["--no-default-whitelist", "--json", "--", target])
        log.unlink()
        for args in (("scan",), ("scan", "--system"), ("scan", "/tmp/not-a-store-path"),
                     ("scan", target + "/../escape"), ("scan", target, "another-target"), ("update", target)):
            self.assertNotEqual(self.run_hey("security", *args).returncode, 0)
            self.assertFalse(log.exists())

    def test_nix_capture_limits_cover_json_raw_and_build_output(self):
        self.isolate_home()
        self.mock_command("nix", 'import json\nprint(json.dumps("x" * (9 * 1024 * 1024)))\n')
        env = self.env | {"PATH": self.env["DOTFILES_BIN"] + os.pathsep + self.env["PATH"]}
        env.pop("HEY_NIX_CAPTURE_LIMIT", None)
        env["JANET_PATH"] = os.pathsep.join([str(ROOT / "vendor/janet"), env.get("JANET_PATH", ""), str(ROOT / "runtime")])
        for expression in ('(nix/eval-json "fixture")', '(nix/eval-raw "fixture")', '(nix/build-output "fixture")'):
            program = f'(use hey/nix) (print (length {expression}))'
            result = subprocess.run(["janet", "-e", program], env=env, cwd=self.consumer,
                                    text=True, capture_output=True, timeout=10)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("captured output exceeded", result.stderr)
            result = subprocess.run(["janet", "-e", program], env=env | {"HEY_NIX_CAPTURE_LIMIT": str(10 * 1024 * 1024)},
                                    cwd=self.consumer, text=True, capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
        for limit in ("0", "-1", "infinity", "1.5"):
            result = subprocess.run(["janet", "-e", '(use hey/nix) (nix/eval-raw "fixture")'],
                                    env=env | {"HEY_NIX_CAPTURE_LIMIT": limit}, cwd=self.consumer,
                                    text=True, capture_output=True, timeout=10)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("positive integer byte count", result.stderr)

    def test_context_signal_reaps_captured_child(self):
        self.diagnostic_fixture()
        pid_file = self.root / "captured-pid"
        self.mock_command("nix", f'import os, time\nfrom pathlib import Path\nPath({str(pid_file)!r}).write_text(str(os.getpid()))\ntime.sleep(5)\n')
        process = subprocess.Popen([str(HEY), "context"], env=self.env, cwd=self.consumer,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 3
            while not pid_file.exists() and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(pid_file.exists())
            process.terminate()
            process.communicate(timeout=5)
            self.assertNotEqual(process.returncode, 0)
            with self.assertRaises(ProcessLookupError):
                os.kill(int(pid_file.read_text()), 0)
        finally:
            if process.poll() is None:
                process.kill()
            process.communicate(timeout=5)

    def test_ssh_wait_bounds_each_probe_and_sleep_and_reaps_timeout(self):
        self.isolate_home()
        self.env["JANET_PATH"] = ":".join([str(ROOT / "runtime"), str(ROOT / "vendor/janet"),
                                          self.env.get("JANET_PATH", "")])
        pid_file = self.root / "ssh-pid"
        for mode in ("hang", "fail", "success"):
            with self.subTest(mode=mode):
                self.mock_command("ssh", f'''import os, time, sys
from pathlib import Path
Path({str(pid_file)!r}).write_text(str(os.getpid()))
if {mode!r} == "hang": time.sleep(20)
sys.exit(255 if {mode!r} == "fail" else 0)
''')
                env = self.env | {"PATH": self.env["DOTFILES_BIN"] + os.pathsep + self.env["PATH"]}
                start = time.monotonic()
                result = subprocess.run(["janet", "-e", '(use hey/ssh) (ssh/wait [] "fixture" 0.5)'],
                                        env=env, capture_output=True, text=True, timeout=4)
                self.assertLess(time.monotonic() - start, 2, result.stderr)
                self.assertEqual(result.returncode == 0, mode == "success", result.stderr)
                if mode != "success":
                    self.assertIn("within 0.5 seconds", result.stderr)
                with self.assertRaises(ProcessLookupError):
                    os.kill(int(pid_file.read_text()), 0)

    def test_executable_lookup_skips_nonexecutables_and_directories(self):
        self.isolate_home()
        first, later = self.root / "first", self.root / "later"
        first.mkdir()
        later.mkdir()
        (first / "probe").write_text("not executable")
        (first / "directory-probe").mkdir()
        executable = later / "probe"
        executable.write_text(f"#!{sys.executable}\nprint('selected executable')\n")
        executable.chmod(0o755)
        (later / "directory-probe").symlink_to(executable)
        (first / "broken").symlink_to(first / "absent")
        self.env["JANET_PATH"] = ":".join([str(ROOT / "runtime"), str(ROOT / "vendor/janet"),
                                          self.env.get("JANET_PATH", "")])
        program = f'''(use hey)
(def dirs [{json.dumps(str(first))} {json.dumps(str(later))}])
(assert (= (path/find "probe" dirs) {json.dumps(str(executable))}))
(assert (= (path/find "directory-probe" dirs) {json.dumps(str(later / "directory-probe"))}))
(assert (nil? (path/find "broken" dirs)))
(assert (nil? (path/find {json.dumps(str(first / "probe"))})))
(assert (nil? (path/find {json.dumps(str(first / "directory-probe"))})))
(assert (not (path/executable? {json.dumps(str(first / "directory-probe"))})))
(assert (= (path/find "later/probe" []) "later/probe"))
(assert (= (path/find {json.dumps(str(executable))} []) {json.dumps(str(executable))}))
'''
        result = subprocess.run(["janet", "-e", program], cwd=self.root, env=self.env,
                                capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.env["DOTFILES_BIN"] = str(first)
        self.env["PATH"] = str(later) + os.pathsep + self.env["PATH"]
        result = self.run_hey("exec", "probe")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("selected executable", result.stdout)

    @unittest.skipUnless(shutil.which("tmux"), "tmux is not available")
    def test_tmux_project_uses_exact_session_targets(self):
        self.isolate_home()
        real_tmux = shutil.which("tmux")
        socket, log = str(self.root / "tmux.sock"), self.root / "tmux-calls"

        def tmux(*args):
            return subprocess.run([real_tmux, "-S", socket, *args], env=self.env,
                                  capture_output=True, text=True, timeout=5)

        self.addCleanup(lambda: tmux("kill-server"))
        result = tmux("-f", "/dev/null", "new-session", "-d", "-s", "api-old",
                      shutil.which("sleep"), "60")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.mock_command("tmux", f'''import json, os, sys
from pathlib import Path
with Path({str(log)!r}).open("a") as stream:
    stream.write(json.dumps(sys.argv[1:]) + "\\n")
if sys.argv[1] == "switch-client": sys.exit(1)
if sys.argv[1] == "attach-session": sys.exit(0)
os.execv({real_tmux!r}, [{real_tmux!r}, "-S", {socket!r}, *sys.argv[1:]])
''')
        for _ in range(2):
            result = self.run_hey("tmux", "project", "api", str(self.consumer))
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(sorted(tmux("list-sessions", "-F", "#S").stdout.splitlines()), ["api", "api-old"])
        calls = [json.loads(line) for line in log.read_text().splitlines()]
        self.assertEqual(sum(call[0] == "new-session" for call in calls), 1)
        for call in calls:
            if call[0] in ("has-session", "switch-client", "attach-session"):
                self.assertEqual(call[-2:], ["-t", "=api"])

    def test_tmux_reload_always_clears_flag_and_preserves_failure(self):
        self.isolate_home()
        self.env["HEY_THEME"] = "kokedera"
        log = self.root / "reload-calls"
        marker = self.root / "reload-marker"
        counter = self.root / "source-count"
        for fail_at, cleanup_status in [(0, 0), (1, 0), (2, 0), (1, 24), (0, 24)]:
            with self.subTest(fail_at=fail_at, cleanup_status=cleanup_status):
                for file in (log, marker, counter):
                    file.unlink(missing_ok=True)
                self.mock_command("tmux", f'''import json, sys
from pathlib import Path
args = sys.argv[1:]
with Path({str(log)!r}).open("a") as output:
    output.write(json.dumps(args) + "\\n")
marker = Path({str(marker)!r})
counter = Path({str(counter)!r})
if args[0] == "set-option":
    if "-u" in args:
        if {cleanup_status}:
            sys.exit({cleanup_status})
        marker.unlink(missing_ok=True)
    else:
        marker.touch()
elif args[0] == "source-file":
    count = int(counter.read_text()) + 1 if counter.exists() else 1
    counter.write_text(str(count))
    if count == {fail_at}:
        sys.exit(23)
''')
                result = self.run_hey("reload", "tmux")
                self.assertEqual(result.returncode, 23 if fail_at else cleanup_status, result.stderr)
                calls = [json.loads(line) for line in log.read_text().splitlines()]
                self.assertIn(["set-option", "-g", "-q", "-u", "@hey_reload"], calls)
                self.assertEqual(marker.exists(), bool(cleanup_status))
                if fail_at or cleanup_status:
                    self.assertNotIn("Done!", result.stdout)
                log.unlink()
                result = self.run_hey("-!", "reload", "tmux")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertFalse(log.exists())

    def start_tmux(self, location):
        """Start only a private server; popup commands are recorded, never opened."""
        real_tmux = shutil.which("tmux")
        home = self.isolate_home()
        self.env["SHELL"] = shutil.which("sh")
        if location == "home":
            self.env.pop("XDG_CONFIG_HOME", None)
            config = home / ".config/tmux"
        else:
            self.env["XDG_CONFIG_HOME"] = str(self.root / "config space ' $(printf CONFIG)")
            config = Path(self.env["XDG_CONFIG_HOME"]) / "tmux"
            if location == "explicit":
                config = self.root / "tmux override ' $(printf OVERRIDE)"
                self.env["TMUX_HOME"] = str(config)
        config.mkdir(parents=True)
        for source in (ROOT / "assets/tmux").rglob("*"):
            target = config / source.relative_to(ROOT / "assets/tmux")
            if source.is_dir():
                target.mkdir(exist_ok=True)
            else:
                target.symlink_to(source)
        (config / "extraInit").write_text("set -g @fixture-extra loaded\n")
        (config / "tmux.local.conf").write_text("set -g @fixture-local loaded\n")
        socket = str(self.root / "tmux.sock")
        log = self.root / "popup-args"
        self.mock_command("tmux", f'''import json, os, sys
from pathlib import Path
if sys.argv[1] == "display-popup":
    Path({str(log)!r}).write_text(json.dumps(sys.argv[1:]))
else:
    os.execv({real_tmux!r}, [{real_tmux!r}, "-S", {socket!r}, *sys.argv[1:]])
''')
        # Helpers launched by the private server must see the same tmux wrapper.
        self.env["PATH"] = self.env["DOTFILES_BIN"] + os.pathsep + self.env["PATH"]
        project = self.root / "project ' $(printf EXPANDED)"
        project.mkdir()
        bootstrap = self.root / "bootstrap.conf"
        bootstrap.write_text("set -g default-shell " + shlex.quote(self.env["SHELL"]) + "\n")

        def tmux(*args, check=True, input=None):
            result = subprocess.run([real_tmux, "-S", socket, *args], env=self.env,
                                    input=input, capture_output=True, text=True, timeout=10)
            if check:
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            return result

        # Register cleanup before startup so even a failed assertion is isolated.
        self.addCleanup(lambda: tmux("kill-server", check=False))
        tmux("-f", str(bootstrap), "new-session", "-d", "-s", "fixture",
             "-c", str(project), shutil.which("sleep"), "120")
        tmux("source-file", str(config / "tmux.conf"))
        return tmux, config, project, log

    @unittest.skipUnless(shutil.which("tmux") and shutil.which("zsh"), "tmux/zsh are not available")
    def test_tmux_config_paths_bindings_and_popup_data_are_literal(self):
        tmux, config, project, log = self.start_tmux("xdg")
        self.assertEqual(tmux("show-options", "-gqv", "@fixture-extra").stdout.strip(), "loaded")
        self.assertEqual(tmux("show-options", "-gqv", "@fixture-local").stdout.strip(), "loaded")
        pane = tmux("display-message", "-p", "#{pane_id}").stdout.strip()
        state = '$(printf INJECTED) "quoted"; arbitrary text'
        tmux("set-option", "-g", "@hey_pane_status_" + pane[1:], "nix=" + state)

        def check_popup(command):
            # list-keys emits tmux syntax, not POSIX sh syntax (notably \$).
            # Replay the stored command through tmux's own parser.
            tmux("source-file", "-", input=command)
            args = json.loads(log.read_text())
            self.assertEqual(Path(args[args.index("-d") + 1]), project.resolve())
            log.unlink()
            return args

        for key in ("G", "N", "E"):
            command = re.sub(r"^bind-key\s+-T\s+\S+\s+\S+\s+", "",
                             tmux("list-keys", "-T", "prefix", key).stdout)
            self.assertNotIn("pane_current_path", command)
            args = check_popup(command)
            if key == "N":
                variable = args[args.index("-e") + 1]
                self.assertEqual(variable, "HEY_TMUX_NIX_STATE=" + state)
                env = {**self.env, "HEY_TMUX_NIX_STATE": state}
                result = subprocess.run([self.env["SHELL"], "-c", args[-1]], cwd=project,
                                        env=env, capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("nix: " + state + "\n", result.stdout)

        menu = tmux("list-keys", "-T", "prefix", "Space").stdout
        for title in ("Git status", "Nix context", "Direnv context"):
            callback = re.search(re.escape(json.dumps(title)) + r" \S+ \{ (.*?) \}", menu).group(1)
            tmux("source-file", "-", input=callback)
            args = json.loads(log.read_text())
            self.assertEqual(Path(args[args.index("-d") + 1]), project.resolve())
            log.unlink()

        # No configuration assumes a consumer checkout when DOTFILES_BIN is unset.
        hey_log = self.root / "hey-args"
        self.mock_command("hey", f'import json, sys\nfrom pathlib import Path\nPath({str(hey_log)!r}).write_text(json.dumps(sys.argv[1:]))\n')
        tmux("set-environment", "-gu", "DOTFILES_BIN")
        for key, expected in [("H", ["tmux", "swap-pane", "left"]), ("r", ["reload", "tmux"])]:
            command = re.sub(r"^bind-key\s+-T\s+\S+\s+\S+\s+", "",
                             tmux("list-keys", "-T", "prefix", key).stdout)
            tmux("source-file", "-", input=command)
            self.assertEqual(json.loads(hey_log.read_text()), expected)

    @unittest.skipUnless(shutil.which("tmux") and shutil.which("zsh"), "tmux/zsh are not available")
    def test_tmux_doctor_accepts_bundled_themes_and_custom_preferences(self):
        tmux, config, project, log = self.start_tmux("explicit")
        for theme in (None, "alucard", "kokedera"):
            with self.subTest(theme=theme):
                if theme:
                    tmux("source-file", str(ROOT / f"modules/shared/themes/{theme}/config/tmux.conf"))
                    binding = tmux("list-keys", "-T", "root", "MouseDown1Status").stdout
                    callback = re.search(r" \{ (.*?) \}", binding).group(1)
                    callback = callback.replace("#{q:mouse_status_range}", "git")
                    tmux("source-file", "-", input=callback)
                    args = json.loads(log.read_text())
                    self.assertEqual(Path(args[args.index("-d") + 1]), project.resolve())
                result = self.run_hey("tmux", "doctor")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("tmux doctor passed", result.stdout)
        tmux("set-option", "-g", "prefix", "C-a")
        tmux("set-option", "-g", "status-left-length", "42")
        tmux("unbind-key", "H")
        result = self.run_hey("tmux", "doctor")
        self.assertEqual(result.returncode, 0, result.stderr)
        tmux("kill-server")
        result = self.run_hey("tmux", "doctor")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("tmux doctor passed", result.stdout)
        result = self.run_hey("-!", "tmux", "doctor")
        self.assertEqual(result.returncode, 0, result.stderr)

    @unittest.skipUnless(shutil.which("tmux") and shutil.which("zsh"), "tmux/zsh are not available")
    def test_tmux_config_defaults_to_home_when_xdg_is_unset(self):
        tmux, config, _, _ = self.start_tmux("home")
        value = tmux("show-environment", "-g", "TMUX_HOME").stdout.strip()
        self.assertEqual(value, "TMUX_HOME=" + str(config))
        self.assertEqual(tmux("show-options", "-gqv", "@fixture-local").stdout.strip(), "loaded")

    def test_direnv_discovers_nearest_envrc_and_propagates_status(self):
        self.isolate_home()
        self.env.pop("DIRENV_FILE", None)
        self.env.pop("DIRENV_DIR", None)
        config = self.root / "config/direnv/direnv.toml"
        config.parent.mkdir(parents=True)
        config.write_text("# fixture\n")
        envrc = self.consumer / ".envrc"
        envrc.write_text("# parent fixture\n")
        nested = self.consumer / "nested/deep"
        nested.mkdir(parents=True)
        log = self.root / "direnv-calls"
        self.mock_command("direnv", f'''import sys
from pathlib import Path
Path({str(log)!r}).write_text("called")
print("fixture status failure", file=sys.stderr)
sys.exit(23)
''')
        for cwd in (self.consumer, nested):
            result = self.run_hey("direnv", "status", cwd=cwd)
            self.assertEqual(result.returncode, 23, result.stderr)
            self.assertIn("envrc: " + str(envrc.resolve()), result.stdout)
            self.assertIn("fixture status failure", result.stderr)
            result = self.run_hey("direnv", "doctor", cwd=cwd)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(".envrc found", result.stdout)
            self.assertIn("fixture status failure", result.stderr)
            self.assertNotIn("doctor passed", result.stdout)
        (nested / ".envrc").write_text("# nearest fixture\n")
        self.mock_command("direnv", 'print("fixture status OK")\n')
        result = self.run_hey("direnv", "status", cwd=nested)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("envrc: " + str((nested / ".envrc").resolve()), result.stdout)
        self.assertIn("fixture status OK", result.stdout)
        result = self.run_hey("direnv", "doctor", cwd=nested)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("doctor passed", result.stdout)
        log.unlink()
        self.mock_command("direnv", f'from pathlib import Path\nPath({str(log)!r}).touch()\n')
        for action in ("doctor", "status", "reload"):
            result = self.run_hey("-!", "direnv", action)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(log.exists())
        # Reaching the filesystem root without an envrc must terminate too.
        result = self.run_hey("direnv", "status", cwd=self.root)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("envrc: <none>", result.stdout)

    def test_watch_selects_sources_and_rejects_nonlocal_flakes(self):
        self.isolate_home()
        log = self.root / "watch-args"
        self.mock_command("watchexec", f'''import json, sys
from pathlib import Path
Path({str(log)!r}).write_text(json.dumps(sys.argv[1:]))
''')
        nested = self.consumer / "nested"
        nested.mkdir()
        fleet = self.root / "other fleet"
        fleet.mkdir()
        cases = [
            (("eval", "laptop"), self.consumer),
            (("flake",), self.consumer),
            (("eval", "laptop", "--flake", "../../other fleet"), fleet),
            (("flake", "--flake", "path:" + str(fleet)), fleet),
            (("cli",), ROOT), (("utm-cli",), ROOT), (("tmux",), ROOT),
            (("run", "example-command", "two words"), nested),
        ]
        for args, expected in cases:
            with self.subTest(args=args):
                result = self.run_hey("watch", *args, cwd=nested)
                self.assertEqual(result.returncode, 0, result.stderr)
                argv = json.loads(log.read_text())
                self.assertIn("--shell=none", argv)
                self.assertEqual(Path(argv[argv.index("--watch") + 1]).resolve(), expected.resolve())
                child = argv[argv.index("--") + 1:]
                if "--flake" in args:
                    self.assertEqual(Path(child[child.index("--flake") + 1]).resolve(), fleet.resolve())
                if args[0] == "run":
                    self.assertEqual(child, ["example-command", "two words"])
                    self.assertNotIn("--exts", argv)
                else:
                    self.assertEqual(child[0], str(HEY))
                if args[0] in ("eval", "flake"):
                    self.assertIn("lock", argv[argv.index("--exts") + 1].split(","))
                log.unlink()
        for ref in ("github:example/fleet", "nixpkgs#host", "path:./fleet?rev=123", "missing-fleet"):
            result = self.run_hey("watch", "eval", "--flake", ref)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(log.exists())
        result = self.run_hey("watch", "cli", "--flake", str(fleet))
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(log.exists())
        result = self.run_hey("-!", "watch", "eval", "--flake", "missing-fleet")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(log.exists())

    @unittest.skipUnless(shutil.which("watchexec"), "watchexec is not available")
    def test_watch_preserves_arguments_through_real_watchexec(self):
        self.isolate_home()
        real_watchexec = shutil.which("watchexec")
        log = self.root / "child-argv"
        self.mock_command("capture-argv", f'''import sys, json
from pathlib import Path
Path({str(log)!r}).write_text(json.dumps(sys.argv[1:]))
sys.exit(2)
''')
        # Exercise the actual command runner once, without kernel file watches
        # or a long-lived process. Only the fixture command is executed.
        self.mock_command("watchexec", f'''import os, sys
args = sys.argv[1:]
args[args.index("--watch") + 1] = "/dev/null"
os.execv({real_watchexec!r}, [{real_watchexec!r}, "--exit-on-error", *args])
''')
        expected = ["two words", "$(printf EXPANDED)", "a;b", "quote'\"", "*.nix"]
        result = self.run_hey("watch", "run", "capture-argv", *expected)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(json.loads(log.read_text()), expected)

    @unittest.skipUnless(shutil.which("watchexec"), "watchexec is not available")
    def test_project_and_dev_watch_preserve_project_paths(self):
        self.isolate_home()
        real_watchexec = shutil.which("watchexec")
        child_log = self.root / "just-args"
        watch_log = self.root / "watch-args"
        self.mock_command("just", f'''import json, os, sys
from pathlib import Path
if '--summary' in sys.argv:
    print('check')
else:
    Path({str(child_log)!r}).write_text(json.dumps([os.getcwd(), sys.argv[1:]]))
    sys.exit(2)
''')
        self.mock_command("watchexec", f'''import json, os, sys
from pathlib import Path
args = sys.argv[1:]
Path({str(watch_log)!r}).write_text(json.dumps(args))
args[args.index('--watch') + 1] = '/dev/null'
os.execv({real_watchexec!r}, [{real_watchexec!r}, '--exit-on-error', *args])
''')
        for name in ("two words", "watch$(printf EXPANDED)"):
            project = self.consumer / name
            source = project / "src"
            source.mkdir(parents=True)
            (project / "justfile").write_text("check:\n    true\n")
            for command in ("project", "dev"):
                with self.subTest(name=name, command=command):
                    result = self.run_hey(command, "watch", cwd=source)
                    self.assertEqual(result.returncode, 2, result.stderr)
                    cwd, argv = json.loads(child_log.read_text())
                    self.assertEqual(Path(cwd), project.resolve())
                    self.assertEqual(argv, ["--justfile", str((project / "justfile").resolve()), "check"])
                    watch = json.loads(watch_log.read_text())
                    self.assertIn("--shell=none", watch)
                    self.assertEqual(Path(watch[watch.index("--watch") + 1]), project.resolve())
                    child_log.unlink()
                    watch_log.unlink()
                    result = self.run_hey("-!", command, "watch", cwd=source)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertFalse(child_log.exists())
                    self.assertFalse(watch_log.exists())

    def test_build_targets_framework_and_keeps_links_in_callers_directory(self):
        self.isolate_home()
        caller = self.consumer / "caller directory"
        caller.mkdir()
        log = self.root / "build-calls"
        for tool in ("nix", "nom"):
            self.mock_command(tool, f'''import json, os, sys
from pathlib import Path
args = sys.argv[1:]
assert args[:3] == ['build', '--impure', '--no-write-lock-file'], args
assert args[4] == '--out-link', args
assert Path.cwd() == Path({str(caller.resolve())!r})
package = args[3].split('#')[-1]
assert args[3] == {('path:' + str(ROOT.resolve()) + '#')!r} + package, args
assert package in ['hey', 'hey-janet-deps'], args
assert args[5] == ('result' if package == 'hey' else 'result-hey-janet-deps'), args
with Path({str(log)!r}).open('a') as stream:
    stream.write(json.dumps([Path(sys.argv[0]).name, package]) + '\\n')
if os.getenv('FIXTURE_FAIL_PACKAGE') == package:
    sys.exit(23)
artifact = Path({str(self.root)!r}) / ('artifact-' + package)
artifact.touch()
Path(args[5]).symlink_to(artifact)
''')
        for use_nom in ("0", "1"):
            self.env["HEY_NIX_USE_NOM"] = use_nom
            for args in ((), ("-a",)):
                expected = ["hey", "hey-janet-deps"] if args else ["hey"]
                result = self.run_hey("-!", "build", *args, cwd=caller)
                self.assertEqual(result.returncode, 0, result.stderr)
                for package in expected:
                    self.assertIn("path:" + str(ROOT) + "#" + package, result.stdout)
                self.assertFalse(log.exists())
                result = self.run_hey("build", *args, cwd=caller)
                self.assertEqual(result.returncode, 0, result.stderr)
                calls = [json.loads(line) for line in log.read_text().splitlines()]
                self.assertEqual(calls, [["nom" if use_nom == "1" else "nix", name] for name in expected])
                self.assertTrue((caller / "result").is_symlink())
                self.assertEqual((caller / "result-hey-janet-deps").is_symlink(), bool(args))
                self.assertFalse((self.consumer / "result").exists())
                log.unlink()
                for link in caller.iterdir():
                    link.unlink()
        self.env["FIXTURE_FAIL_PACKAGE"] = "hey"
        result = self.run_hey("build", "-a", cwd=caller)
        self.assertEqual(result.returncode, 23, result.stderr)
        self.assertEqual(len(log.read_text().splitlines()), 1)
        self.assertNotIn("Done!", result.stdout)
        self.assertEqual(list(caller.iterdir()), [])

    def test_cache_cleanup_rejects_unsafe_roots_before_deleting(self):
        self.isolate_home()
        project = self.consumer / "zsh"
        project.mkdir()
        (project / "source.zsh").write_text("keep me")
        cache = self.root / "cache/zsh"
        cache.mkdir(parents=True)
        for name in ("HOME", "XDG_CACHE_HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME",
                     "XDG_STATE_HOME", "XDG_RUNTIME_DIR"):
            original = self.env[name]
            for value in (".", "relative", "/", "/tmp/.."):
                with self.subTest(name=name, value=value):
                    self.env[name] = value
                    result = self.run_hey("clean", "all")
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(name, result.stderr)
                    self.assertTrue(cache.exists())
                    self.assertEqual((project / "source.zsh").read_text(), "keep me")
            self.env[name] = original

    def test_cache_cleanup_empty_xdg_uses_home_and_respects_custom_config(self):
        home = self.isolate_home()
        cache = home / ".cache/zsh"
        cache.mkdir(parents=True)
        (cache / "cache-file").touch()
        config = self.root / "config with spaces/zsh"
        config.mkdir(parents=True)
        (config / ".zcompdump").touch()
        project = self.consumer / "zsh"
        project.mkdir()
        self.env["XDG_CACHE_HOME"] = ""
        self.env["XDG_CONFIG_HOME"] = str(config.parent)
        result = self.run_hey("-!", "clean", "zsh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(cache.exists())
        result = self.run_hey("clean", "zsh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(cache.exists())
        self.assertFalse((config / ".zcompdump").exists())
        self.assertTrue(project.exists())

    def test_cache_cleanup_does_not_follow_final_symlinks(self):
        self.isolate_home()
        project = self.consumer / "source"
        project.mkdir()
        (project / "keep").touch()
        cache = self.root / "cache/zsh"
        cache.parent.mkdir(parents=True)
        cache.symlink_to(project, target_is_directory=True)
        result = self.run_hey("clean", "zsh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(cache.is_symlink())
        self.assertTrue((project / "keep").exists())

    def mock_utm_creation(self, failure=""):
        home = self.isolate_home()
        documents = home / "Library/Containers/com.utmapp.UTM/Data/Documents"
        image = self.root / "image-output"
        image.mkdir(exist_ok=True)
        (image / "fixture.qcow2").write_text("fixture")
        state = self.root / "vm-present"
        state.touch()
        log = self.root / "vm-operations"
        log.write_text("")
        preamble = f'''import json, sys
from pathlib import Path
def record(event):
    with Path({str(log)!r}).open('a') as f: f.write(event + '\\n')
'''
        directory = self.mock_command("md5", "print('MD5 = 0123456789abcdef0123456789abcdef')\n")
        self.mock_command("utmctl", preamble + f'''
if {failure!r} == 'query': sys.exit(7)
if sys.argv[1] == 'list':
    print('UUID STATUS NAME')
    if Path({str(state)!r}).exists(): print('fixture stopped review')
elif sys.argv[1] == 'status': print('stopped')
else: sys.exit(91)
''')
        self.mock_command("nix", preamble + f'''
if sys.argv[1] == 'build':
    record('build')
    if {failure!r} == 'build': sys.exit(7)
    print({str(image)!r})
elif sys.argv[1] == 'eval': print('{{}}')
else: sys.exit(91)
''')
        self.mock_command("qemu-img", preamble + f'''
record(sys.argv[1])
if {failure!r} == sys.argv[1]: sys.exit(7)
if sys.argv[1] == 'convert':
    Path(sys.argv[-1]).write_bytes(b'' if {failure!r} == 'empty' else b'raw image')
''')
        self.mock_command("osascript", preamble + f'''
if 'delete vm' in sys.argv[2]:
    record('delete')
    Path({str(state)!r}).unlink()
elif 'make new virtual machine' in sys.argv[2]:
    record('create')
    if {failure!r} == 'create': sys.exit(7)
    Path({str(state)!r}).touch()
    plist = Path({str(documents)!r}) / 'review.utm/config.plist'
    plist.parent.mkdir(parents=True, exist_ok=True)
    plist.write_text('{{}}')
else: sys.exit(91)
''')
        self.mock_command("plutil", '''import shutil, sys
if '-o' in sys.argv: shutil.copyfile(sys.argv[-1], sys.argv[sys.argv.index('-o') + 1])
''')
        self.env["PATH"] = str(directory) + os.pathsep + self.env["PATH"]
        self.env["HEY_NIX_USE_NOM"] = "0"
        return state, log, documents / "HeyImages"

    def create_mock_vm(self):
        return self.run_hey("utm", "create-image", "--vm", "review", "--flake", ".#review",
                            "--force", "--yes")

    def test_vm_replacement_preparation_failures_preserve_old_vm(self):
        for failure in ("query", "build", "convert", "info", "empty"):
            with self.subTest(failure=failure):
                state, log, staging = self.mock_utm_creation(failure)
                result = self.create_mock_vm()
                self.assertNotEqual(result.returncode, 0)
                self.assertTrue(state.exists())
                self.assertNotIn("delete", log.read_text())
                self.assertNotIn("create", log.read_text())
                self.assertEqual(list(staging.glob(".nixi-image.*")), [])

    def test_vm_replacement_validates_before_delete_and_cleans_success(self):
        state, log, staging = self.mock_utm_creation()
        result = self.create_mock_vm()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(log.read_text().splitlines(), ["build", "convert", "info", "delete", "create"])
        self.assertTrue(state.exists())
        self.assertEqual(list(staging.iterdir()), [])

    def test_failed_vm_creation_retains_validated_replacement(self):
        state, log, staging = self.mock_utm_creation("create")
        result = self.create_mock_vm()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(log.read_text().splitlines(), ["build", "convert", "info", "delete", "create"])
        self.assertFalse(state.exists())
        images = list(staging.glob(".nixi-image.*/disk.img"))
        self.assertEqual(len(images), 1)
        self.assertEqual(images[0].read_bytes(), b"raw image")
        self.assertIn(str(images[0]), result.stdout + result.stderr)

    def test_vm_creation_rejects_names_that_escape_storage(self):
        self.mock_utm_creation()
        for name in ("../review", "/tmp/review", ".", ".."):
            result = self.run_hey("-!", "utm", "create-image", "--vm", name, "--flake", ".#review")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("VM name", result.stderr)

    def test_vm_wait_is_bounded_and_query_errors_are_not_absence(self):
        self.mock_utm_creation()
        self.env["JANET_PATH"] = ":".join([str(ROOT / "runtime"), str(ROOT / "vendor/janet"),
                                             self.env.get("JANET_PATH", "")])
        result = subprocess.run(["janet", "-e", '(use hey/vm) (vm/wait-for "review" false 0)'],
                                env=self.env, text=True, capture_output=True, timeout=5)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Timed out", result.stderr)
        self.mock_command("utmctl", "import sys\nsys.exit(7)\n")
        result = subprocess.run(["janet", "-e", '(use hey/vm) (vm/exists? "review")'],
                                env=self.env, text=True, capture_output=True, timeout=5)
        self.assertNotEqual(result.returncode, 0)

    def test_iso_build_never_targets_system_profile(self):
        log = self.root / "nix-args"
        directory = self.mock_command("nix", f'''import json, sys
from pathlib import Path
Path({str(log)!r}).write_text(json.dumps(sys.argv[1:]))
''')
        self.env["PATH"] = str(directory) + os.pathsep + self.env["PATH"]
        self.env.pop("HEY_NIX_USE_NOM", None)
        result = self.run_hey("-!", "build", "iso")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--out-link result-iso", result.stdout)
        self.assertNotIn("--profile", result.stdout)
        self.assertFalse(log.exists())
        result = self.run_hey("build", "iso")
        self.assertEqual(result.returncode, 0, result.stderr)
        argv = json.loads(log.read_text())
        self.assertEqual(argv[-3:], ["--out-link", "result-iso", "--print-out-paths"])
        self.assertNotIn("--profile", argv)

    def test_failed_hooks_and_forced_retries_do_not_record_success(self):
        failed = self.root / "fail"
        log = self.root / "hook-runs"
        self.install_hook("review", f'''import sys
from pathlib import Path
with Path({str(log)!r}).open("a") as f: f.write("run\\n")
sys.exit(7 if Path({str(failed)!r}).exists() else 0)
''')
        self.assertEqual(self.run_hey("hook", "review").returncode, 0)
        self.assertNotEqual(self.run_hey("hook", "review").returncode, 0)
        failed.touch()
        for args in (("-f",), (), ()):
            result = self.run_hey("hook", "review", *args)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn("Triggered", result.stdout)
            self.assertNotIn("Redundant", result.stderr)
            self.assertFalse((self.root / "runtime/hey/hook.lock").exists())
        failed.unlink()
        self.assertEqual(self.run_hey("hook", "review").returncode, 0)
        self.assertEqual(len(log.read_text().splitlines()), 5)
        before = log.read_bytes()
        self.assertEqual(self.run_hey("-!", "hook", "review").returncode, 0)
        self.assertEqual(log.read_bytes(), before)

    def test_concurrent_hooks_deduplicate_inside_lock(self):
        log = self.root / "hook-runs"
        self.install_hook("review", f'''import time
from pathlib import Path
with Path({str(log)!r}).open("a") as f: f.write("run\\n")
time.sleep(0.3)
''')
        processes = [subprocess.Popen([str(HEY), "hook", "review"], cwd=self.consumer,
                                     env=self.env, text=True, stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE) for _ in range(2)]
        for process in processes:
            self.addCleanup(lambda p=process: p.kill() if p.poll() is None else None)
        results = [process.communicate(timeout=30) for process in processes]
        self.assertEqual(sorted(process.returncode for process in processes), [0, 127], results)
        self.assertEqual(log.read_text(), "run\n")

    def test_reload_propagates_hook_failure_without_updating_plugins(self):
        self.install_hook("reload", "import sys\nsys.exit(7)\n")
        for target in ("zsh", "all"):
            result = self.run_hey("reload", target)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn("Done!", result.stdout)
            self.assertNotIn("zsh caches cleared", result.stdout)
            self.assertNotIn("zgenom", result.stdout + result.stderr)

    def test_eks_ssh_preserves_structured_arguments(self):
        config = self.root / "config/hey"
        config.mkdir(parents=True)
        (config / "aws.json").write_text(json.dumps({"awscli2": {"eksClusters": {
            "review": {"name": "review", "profile": "review", "region": "eu-west-1"}}}}))
        log = self.root / "remote-args"
        directory = self.mock_command("hey", f'''import json, sys
from pathlib import Path
if sys.argv[1:3] == ["utm", "ip"]: print("192.0.2.1")
else: Path({str(log)!r}).write_text(json.dumps(sys.argv[1:]))
''')
        self.mock_command("ssh", '''import shlex, subprocess, sys
idx = next(i for i, arg in enumerate(sys.argv) if "@192.0.2.1" in arg)
remote = " ".join(sys.argv[idx + 1:])
if shlex.split(remote)[:2] == ["hey", "eks"]:
    sys.exit(subprocess.run(["sh", "-c", remote]).returncode)
# Never execute the VPN startup script or contact a real host.
''')
        self.env["PATH"] = str(directory) + os.pathsep + self.env["PATH"]
        for query in ("api|worker", "two words", "", "it's quoted", "$(printf injected)", "*", "a\nb"):
            result = self.run_hey("eks", "--bastion", "fixture", "logs", "review", query)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(log.read_text()), ["eks", "logs", "review", query])
        result = self.run_hey("eks", "--bastion", "fixture", "port-forward", "review", "svc/api", "8080:80")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(log.read_text()), ["eks", "port-forward", "review", "svc/api", "8080:80"])

    def test_pull_override_parsing_and_mapped_revision(self):
        log = self.root / "nix-args"
        metadata = {"locks": {"root": "root", "nodes": {
            "root": {"inputs": {"home-manager": ["alias"], "alias": "renamed-node"}},
            "renamed-node": {"original": {"type": "github", "owner": "example", "repo": "home"}}}}}
        self.mock_command("nix", f'''import json, sys
from pathlib import Path
if sys.argv[1:3] == ["flake", "metadata"]:
    assert "--no-write-lock-file" in sys.argv
    print({json.dumps(metadata)!r})
else: Path({str(log)!r}).write_text(json.dumps(sys.argv[1:]))
''')
        for value in ("home-manager=github:example/home", "home-manager@abc123"):
            result = self.run_hey("-!", "pull", "-o", value)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("--flake", result.stdout)
            self.assertFalse(log.exists())
        result = self.run_hey("pull", "-o", "home-manager@abc123")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(log.read_text()), ["flake", "update", "--flake", str(self.consumer),
                         "--refresh", "--override-input", "home-manager", "github:example/home/abc123",
                         "home-manager"])
        for value in ("bad", "home-manager=", "home-manager@", "=value", "@rev"):
            result = self.run_hey("-!", "pull", "-o", value)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Malformed input spec", result.stderr)
        self.assertNotEqual(self.run_hey("-!", "pull", "-o").returncode, 0)

    @unittest.skipUnless(shutil.which("nix"), "nix is not available")
    def test_pull_override_with_real_isolated_nix(self):
        self.isolate_home()
        self.isolate_nix()
        for name in ("old", "new", "unrelated"):
            directory = self.root / name
            directory.mkdir()
            (directory / "flake.nix").write_text('{ outputs = _: {}; }\n')
        (self.consumer / "flake.nix").write_text(
            '{ inputs.home-manager.url = "path:' + str((self.root / "old").resolve()) + '"; '
            'inputs.unrelated.url = "path:' + str((self.root / "unrelated").resolve()) + '"; '
            'outputs = _: {}; }\n')
        subprocess.run(["nix", "flake", "lock", str(self.consumer.resolve())],
                       env=self.env, capture_output=True, text=True, check=True, timeout=30)
        before = json.loads((self.consumer / "flake.lock").read_text())
        # Make an unrelated upstream change available. A targeted override must
        # leave this entire locked node, not just its declared URL, unchanged.
        (self.root / "unrelated/flake.nix").write_text('{ outputs = _: { changed = true; }; }\n')
        result = self.run_hey("pull", "-o", "home-manager=path:" + str((self.root / "new").resolve()))
        self.assertEqual(result.returncode, 0, result.stderr)
        lock = json.loads((self.consumer / "flake.lock").read_text())
        node = lock["nodes"][lock["nodes"]["root"]["inputs"]["home-manager"]]
        self.assertEqual(node["locked"]["path"], str((self.root / "new").resolve()))
        unrelated = before["nodes"]["root"]["inputs"]["unrelated"]
        self.assertEqual(lock["nodes"]["root"]["inputs"]["unrelated"], unrelated)
        self.assertEqual(lock["nodes"][unrelated], before["nodes"][unrelated])

    def test_template_rejects_paths_before_copying(self):
        log = self.root / "rsync-args"
        self.mock_command("rsync", f'from pathlib import Path\nPath({str(log)!r}).touch()\n')
        target = self.root / "target"
        for name in (".", "..", "../..", "rust/..", "rust/", "./rust", str(ROOT)):
            for prefix in ((), ("-!",)):
                with self.subTest(name=name, prefix=prefix):
                    result = self.run_hey(*prefix, "template", "init", name, str(target))
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("Unknown template", result.stderr)
                    self.assertFalse(target.exists())
                    self.assertFalse(log.exists())

    def test_template_rejects_source_symlink_escape(self):
        # Copy only the CLI launcher/commands; never alter the real framework.
        framework = self.root / "framework"
        shutil.copytree(ROOT / "bin", framework / "bin")
        for name in ("runtime", "vendor"):
            (framework / name).symlink_to(ROOT / name, target_is_directory=True)
        templates = framework / "templates"
        (templates / "valid").mkdir(parents=True)
        outside = framework / "templates-outside"
        outside.mkdir()
        (templates / "escape").symlink_to(outside, target_is_directory=True)
        (templates / "root-alias").symlink_to(templates, target_is_directory=True)
        launcher = str(framework / "bin/hey")
        result = subprocess.run([launcher, "template", "list"], cwd=self.consumer,
                                env=self.env, text=True, capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "valid")
        target = self.root / "target"
        for name in ("escape", "root-alias"):
            result = subprocess.run([launcher, "template", "init", name, str(target)],
                                    cwd=self.consumer, env=self.env, text=True,
                                    capture_output=True, timeout=30)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Unknown template", result.stderr)
            self.assertFalse(target.exists())

    @unittest.skipUnless(shutil.which("rsync"), "rsync is not available")
    def test_template_copies_to_local_targets_and_preserves_nonempty_targets(self):
        for name in ("with spaces", "./-leading-option", "host:local"):
            with self.subTest(name=name):
                target = self.consumer / name
                result = self.run_hey("-!", "template", "init", "rust", name)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("rsync -a --chmod=u+w --", result.stdout)
                self.assertFalse(target.exists())
                result = self.run_hey("template", "init", "rust", name)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual((target / "flake.nix").read_bytes(),
                                 (ROOT / "templates/rust/flake.nix").read_bytes())
                (target / "flake.nix").write_text("consumer changes")
                result = self.run_hey("template", "init", "rust", name)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Target directory is not empty", result.stderr)
                self.assertEqual((target / "flake.nix").read_text(), "consumer changes")

    @unittest.skipUnless(shutil.which("nix"), "nix is not available")
    def test_host_diagnostics_use_evaluated_config_and_opt_in_policy(self):
        self.isolate_nix()
        # A stale descriptor must not override the actual flake output.
        stale = self.consumer / "hosts/review/default.nix"
        stale.parent.mkdir(parents=True)
        stale.write_text('throw "must not import the descriptor"\n')
        flake = '''{ outputs = _: { nixosConfigurations.review = {
          pkgs.stdenv.hostPlatform.system = "x86_64-linux";
          options.modules.shell.git.enable._type = "option";
          options.modules.secretData._type = "option";
          options.modules.profiles.workstation.enable._type = "option";
          options.modules.profiles.private._type = "option";
          config.modules = {
            shell.git.enable = true;
            secretData = throw "must not inspect unrelated data";
            profiles.workstation.enable = true;
            profiles.private = throw "must not serialize private profile data";
          };
        }; }; }'''
        (self.consumer / "flake.nix").write_text(flake)
        for layout in ("stale", "inline"):
            if layout == "inline": stale.unlink()
            result = self.run_hey("host", "explain", "review")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("shell.git", result.stdout)
            self.assertIn("workstation: enabled", result.stdout)
            command = next(line.removeprefix("build command: ") for line in result.stdout.splitlines()
                           if line.startswith("build command: "))
            argv = shlex.split(command)
            self.assertEqual(argv[1:5], ["check", "build", "review", "--flake"])
            self.assertEqual(self.run_hey("-!", *argv[1:]).returncode, 0)
        result = self.run_hey("host", "doctor", "review")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("opt-in", result.stdout)
        result = self.run_hey("host", "doctor", "review", "--storage")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("fstrim", result.stderr)
        (self.consumer / "flake.nix").write_text(flake.replace('shell.git.enable = true;', 'shell.git.enable = throw "fixture evaluation failed";'))
        result = self.run_hey("host", "explain", "review")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("fixture evaluation failed", result.stderr)

    def test_removed_ssh_cleanup_never_queries_or_kills_processes(self):
        # A healthy forwarding process must not become an automatic kill target.
        log = self.root / "process-probes"
        directory = self.mock_command("ps", f'''from pathlib import Path
Path({str(log)!r}).touch()
print("alice 424242 0.0 0.0 100 100 ?? S 12:00 0:00.01 ssh -N -L 5432:localhost:5432 bastion")
''')
        self.mock_command("kill", f'from pathlib import Path\nPath({str(log)!r}).touch()\n')
        self.env["PATH"] = str(directory) + os.pathsep + self.env["PATH"]
        for prefix in ([], ["-!"]):
            result = self.run_hey(*prefix, "ssh", "kill-stale")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Automatic SSH termination was removed", result.stderr)
            self.assertFalse(log.exists())

    def probe_diagnostic_fixture(self):
        self.isolate_home()
        for key in ("HEY_SSH_DOCTOR_PS", "HEY_SSH_DOCTOR_LSOF"):
            self.env.pop(key, None)
        manifest = self.root / "data/hey/capabilities.json"
        manifest.parent.mkdir(parents=True)
        manifest.write_text(json.dumps({"version": 1, "groups": {"agents": {}}}))
        self.mock_command("ps", "pass\n")
        self.mock_command("lsof", "import sys\nsys.exit(1)\n")

    def test_failed_process_probes_cannot_report_healthy(self):
        self.probe_diagnostic_fixture()
        for status in (1, 42, 124, 125):
            self.mock_command("ps", f"import sys\nprint('fixture probe failure', file=sys.stderr)\nsys.exit({status})\n")
            for args in (("ssh", "doctor", "--verbose"), ("ssh", "ps"),
                         ("doctor", "agents", "--verbose")):
                result = self.run_hey(*args)
                self.assertNotEqual(result.returncode, 0, (args, status, result.stdout))
                self.assertIn("probe fail", result.stderr.lower())
                self.assertNotIn("no ssh processes found", result.stdout)
                self.assertNotIn("agents doctor passed", result.stdout)

    def test_empty_process_tables_and_lsof_no_matches_are_success(self):
        self.probe_diagnostic_fixture()
        result = self.run_hey("ssh", "doctor", "--verbose")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("no ssh processes found", result.stdout)
        result = self.run_hey("doctor", "agents")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("agents doctor passed", result.stdout)
        for status, out, err in ((1, "", "permission denied"), (1, "partial output", ""), (42, "", "")):
            self.mock_command("lsof", f"import sys\nsys.stdout.write({out!r})\nsys.stderr.write({err!r})\nsys.exit({status})\n")
            result = self.run_hey("ssh", "doctor", "--verbose")
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn("no listening TCP ports", result.stdout)

    def test_ssh_process_snapshot_has_parents_and_rejects_malformed_rows(self):
        self.probe_diagnostic_fixture()
        for parent in (1, 42):
            self.mock_command("ps", f'''import sys
assert sys.argv[1:] == ["-ax", "-o", "pid=,ppid=,stat=,etime=,command="]
print("424242 {parent} S 00:10 ssh example.invalid")
''')
            result = self.run_hey("ssh", "doctor", "--verbose")
            self.assertEqual(result.returncode, 0, result.stderr)
            output = result.stdout + result.stderr
            self.assertEqual("1 orphaned ssh process(es)" in output, parent == 1)
            self.assertEqual("no orphaned ssh processes found" in output, parent != 1)
        self.mock_command("ps", "print('malformed SYNTHETIC_PRIVATE_VALUE')\n")
        for command in (("ssh", "doctor"), ("ssh", "ps"), ("doctor", "agents"), ("doctor", "nix")):
            result = self.run_hey(*command)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("probe fail", result.stderr.lower())
            self.assertNotIn("SYNTHETIC_PRIVATE_VALUE", result.stdout + result.stderr)
        self.env["HEY_SSH_DOCTOR_PS"] = "malformed SYNTHETIC_PRIVATE_VALUE"
        result = self.run_hey("ssh", "doctor")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("SYNTHETIC_PRIVATE_VALUE", result.stdout + result.stderr)

    def test_zed_doctor_rejects_failed_partial_extension_discovery(self):
        self.isolate_home()
        self.mock_command("uname", "print('Linux')\n")
        self.mock_command("zed", "pass\n")
        settings = self.root / "config/zed/settings.json"
        settings.parent.mkdir(parents=True)
        settings.write_text("{}")
        desired = self.root / "data/hey/zed-extensions.json"
        desired.parent.mkdir(parents=True)
        desired.write_text(json.dumps({"extensions": ["rust"]}))
        (self.root / "data/zed/extensions/installed").mkdir(parents=True)
        for status in (0, 7, 124, 125):
            self.mock_command("find", f"import sys\nprint('rust')\nsys.exit({status})\n")
            result = self.run_hey("doctor", "zed")
            self.assertEqual(result.returncode == 0, status == 0, result.stderr)
            self.assertEqual("zed doctor passed" in result.stdout, status == 0)
            if status:
                self.assertIn("Zed extension discovery failed", result.stderr)

    def test_ssh_doctor_rejects_invalid_material_and_unverified_references(self):
        import base64
        self.probe_diagnostic_fixture()
        ssh = self.root / "home/.ssh"
        ssh.mkdir()
        trust, config = ssh / "nixi_known_hosts", ssh / "config"
        # Synthetic public key encoding, never a user's signing identity.
        public = b"ssh-ed25519 " + base64.b64encode(b'\0\0\0\x0bssh-ed25519\0\0\0\x20' + bytes(range(32)))
        trust.write_bytes(b"@cert-authority *.example.invalid " + public + b"\n")
        for text, valid, message in [
                ('# UserKnownHostsFile ~/.ssh/nixi_known_hosts\n', False, 'lacks a verified'),
                ('Host *\nUserKnownHostsFile "~/.ssh/nixi_known_hosts"\n', True, 'reference verified'),
                ('Match exec "false"\nUserKnownHostsFile ~/.ssh/nixi_known_hosts\n', False, 'unverified')]:
            config.write_text(text)
            result = self.run_hey("ssh", "doctor")
            self.assertEqual(result.returncode == 0, valid, result.stdout + result.stderr)
            self.assertIn(message, result.stdout + result.stderr)
        config.write_text('Host *\nUserKnownHostsFile ~/.ssh/nixi_known_hosts\n')
        trust.write_text('@cert-authority *.example.invalid SYNTHETIC_PRIVATE_VALUE\n')
        result = self.run_hey("ssh", "doctor")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('SYNTHETIC_PRIVATE_VALUE', result.stdout + result.stderr)
        trust.unlink()
        (ssh / "id_ed25519-cert.pub").write_text('SYNTHETIC_PRIVATE_VALUE\n')
        result = self.run_hey("ssh", "doctor", "--quiet")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("certificate validation failed", result.stderr)
        self.assertNotIn('SYNTHETIC_PRIVATE_VALUE', result.stdout + result.stderr)
        result = self.run_hey("-!", "ssh", "doctor")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("DRYRUN: validate", result.stdout)

    def test_ssh_diagnostic_timeout_and_output_limit_fail_closed(self):
        self.probe_diagnostic_fixture()
        for body, message in (("import time\ntime.sleep(11)\n", "timed out"),
                              ("print('x' * (9 * 1024 * 1024))\n", "captured output exceeded")):
            self.mock_command("ps", body)
            result = self.run_hey("ssh", "doctor", "--verbose")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(message, result.stderr)
            self.assertNotIn("no ssh processes found", result.stdout)

    def test_consumer_untracked_scan_and_single_process_snapshot(self):
        self.isolate_home()
        self.env.update(GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_SYSTEM="/dev/null")
        subprocess.run(["git", "init", "--quiet", str(self.root)], env=self.env, check=True)
        subprocess.run(["git", "-C", str(self.consumer), "add", "--", "flake.nix"], env=self.env, check=True)
        (self.consumer / "modules").mkdir()
        (self.consumer / "modules/new-module.nix").write_text("{ ... }: {}\n")
        (self.root / "private-sibling.nix").write_text("{}\n")
        (self.consumer / ".gitignore").write_text("ignored.nix\n")
        (self.consumer / "ignored.nix").write_text("{}\n")
        calls = self.root / "ps-calls"
        self.mock_command("ps", f'''from pathlib import Path
with Path({str(calls)!r}).open("a") as log: log.write("ps\\n")
print("321 1 S 00:00 /nix/store/fixture-nix-2.0/bin/nix-daemon")
''')
        self.mock_command("nix", "import sys\nprint('true' if sys.argv[1:] == ['config', 'show', 'sandbox'] else 'fixture daemon reachable')\n")
        result = self.run_hey("doctor", "nix", "--verbose")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("modules/new-module.nix", result.stderr)
        self.assertNotIn("private-sibling.nix", result.stdout + result.stderr)
        self.assertNotIn("ignored.nix", result.stdout + result.stderr)
        self.assertNotIn("no non-ignored untracked", result.stdout)
        self.assertEqual(calls.read_text().splitlines(), ["ps"])
        self.mock_command("git", "import sys\nprint('fixture git failure', file=sys.stderr)\nsys.exit(42)\n")
        result = self.run_hey("doctor", "nix", "--verbose")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("untracked file scan failed", result.stderr)
        self.assertNotIn("nix doctor passed", result.stdout)

    def test_non_git_consumer_explicitly_skips_untracked_check(self):
        self.isolate_home()
        self.env.update(GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_SYSTEM="/dev/null")
        self.mock_command("nix", "import sys\nprint('true' if sys.argv[1:] == ['config', 'show', 'sandbox'] else 'fixture daemon reachable')\n")
        self.mock_command("ps", "print('321 1 S 00:00 /nix/store/fixture-nix-2.0/bin/nix-daemon')\n")
        result = self.run_hey("doctor", "nix", "--verbose")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("check skipped", result.stderr)
        self.assertNotIn("no non-ignored untracked", result.stdout)

    def test_nix_sandbox_diagnostic_is_scalar_redacted_and_read_only(self):
        self.probe_diagnostic_fixture()
        self.mock_command("ps", "print('321 1 S 00:00 /nix/store/fixture-nix-2.0/bin/nix-daemon')\n")
        self.mock_command("git", "pass\n")
        calls = self.root / "sandbox-calls"
        for value, status, expected in (
                ("true", 0, "client requests build sandboxing"),
                ("false", 0, "Client build sandbox is disabled"),
                ("relaxed", 0, "Client build sandbox is relaxed"),
                ("SYNTHETIC_PRIVATE_VALUE", 0, "Unrecognized client build sandbox policy"),
                ("true", 42, "Could not inspect client build sandbox policy")):
            with self.subTest(value=value, status=status):
                self.mock_command("nix", f'''import sys
from pathlib import Path
args = sys.argv[1:]
if args == ["config", "show", "sandbox"]:
    with Path({str(calls)!r}).open("a") as log: log.write("scalar\\n")
    print({value!r})
    print("SYNTHETIC_PRIVATE_VALUE", file=sys.stderr)
    sys.exit({status})
assert args == ["store", "info", "--store", "daemon"], args
''')
                result = self.run_hey("doctor", "nix", "--verbose")
                self.assertEqual(result.returncode == 0, status == 0 and value in ("true", "false", "relaxed"), result.stderr)
                self.assertIn(expected, result.stdout + result.stderr)
                self.assertNotIn("SYNTHETIC_PRIVATE_VALUE", result.stdout + result.stderr)
        self.assertEqual(calls.read_text().splitlines(), ["scalar"] * 5)
        result = self.run_hey("-!", "doctor", "nix")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("DRYRUN: nix config show sandbox", result.stdout)
        self.assertEqual(calls.read_text().splitlines(), ["scalar"] * 5)

    def test_retired_swap_preserves_edits_and_legacy_inventory(self):
        editable = self.root / "editable"
        editable.write_text("local edits must survive\n")
        original = self.root / "original"
        original.write_text("original fixture\n")
        saved = editable.with_name("editable.swapped")
        saved.symlink_to(original)
        dangling = self.root / "dangling"
        dangling.write_text("another local edit\n")
        dangling.with_name("dangling.swapped").symlink_to(self.root / "missing-original")
        registry = self.root / "data/hey/swap"
        registry.parent.mkdir(parents=True)
        entries = " ".join(json.dumps(str(p)) for p in (editable, dangling))
        script = f'(spit {json.dumps(str(registry))} (marshal @[{entries}]))'
        subprocess.run(["janet", "-e", script], env=self.env, check=True)
        before = registry.read_bytes()
        for prefix in ([], ["-!"]):
            for args in ((str(editable),), ("-u", str(editable)), ("--reset",), ("-u", "-f", str(editable))):
                result = self.run_hey(*prefix, "swap", *args)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Swap mutations were removed", result.stderr)
                self.assertEqual(editable.read_text(), "local edits must survive\n")
                self.assertEqual(original.read_text(), "original fixture\n")
                self.assertEqual(saved.readlink(), original)
                self.assertEqual(registry.read_bytes(), before)
        result = self.run_hey("swap", "--list")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(str(editable), result.stdout)
        self.assertIn(str(dangling), result.stdout)
        self.assertFalse((self.root / "runtime").exists())

    def test_variables_reject_path_keys_before_touching_state(self):
        for prefix in ([], ["-!"]):
            for key in ("", ".", "..", "../escaped", "nested/key", "back\\slash", str(self.root / "outside")):
                result = self.run_hey(*prefix, "vars", "set", key, "value")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Variable keys must be single file names", result.stderr)
                self.assertFalse((self.root / "runtime").exists())
                self.assertFalse((self.root / "outside").exists())

    def test_variable_dry_run_never_creates_or_overwrites_state(self):
        result = self.run_hey("-!", "vars", "set", "fixture", "preview")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("DRYRUN", result.stdout)
        self.assertFalse((self.root / "runtime").exists())
        result = self.run_hey("vars", "set", "fixture", "original")
        self.assertEqual(result.returncode, 0, result.stderr)
        file = self.root / "runtime/hey/vars.d/fixture"
        before = file.read_bytes()
        result = self.run_hey("-!", "vars", "set", "fixture", "preview")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(file.read_bytes(), before)
        self.assertEqual(file.stat().st_mode & 0o777, 0o600)
        self.assertEqual(file.parent.stat().st_mode & 0o777, 0o700)

    def test_variable_atomic_replacement_and_failure_preserve_other_files(self):
        self.assertEqual(self.run_hey("vars", "set", "fixture", "original").returncode, 0)
        file = self.root / "runtime/hey/vars.d/fixture"
        snapshot = file.with_name("snapshot")
        os.link(file, snapshot)
        before = snapshot.read_bytes()
        result = self.run_hey("vars", "set", "fixture", "replacement")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotEqual(file.stat().st_ino, snapshot.stat().st_ino)
        self.assertEqual(snapshot.read_bytes(), before)
        file.unlink()
        file.symlink_to(snapshot)
        result = self.run_hey("vars", "get", "fixture")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Variable is not a regular file", result.stderr)
        result = self.run_hey("vars", "set", "fixture", "replace link")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(file.is_symlink())
        self.assertEqual(snapshot.read_bytes(), before)
        before = file.read_bytes()
        self.mock_command("mktemp", 'import sys\nsys.exit(7)\n')
        result = self.run_hey("vars", "set", "fixture", "failed replacement")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(file.read_bytes(), before)
        self.assertEqual(sorted(p.name for p in file.parent.iterdir()), ["fixture", "snapshot"])

    def test_check_suite_dry_runs_do_not_create_state(self):
        for suite in ("cli", "unit", "utm-cli"):
            result = self.run_hey("-!", "check", suite)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("DRYRUN: run", result.stdout)
            self.assertFalse((self.root / "runtime").exists())

    def test_gc_prunes_only_selected_profiles_before_collection(self):
        log = self.root / "commands.jsonl"
        body = f'''import json, os, sys
from pathlib import Path
command = [Path(sys.argv[0]).name, *sys.argv[1:]]
with Path({str(log)!r}).open("a") as output:
    output.write(json.dumps(command) + "\\n")
if "nix-env" in command and os.environ.get("NIXI_FAIL_PRUNE"):
    sys.exit(7)
'''
        for command in ("sudo", "nix-env", "nix-store", "nix-collect-garbage"):
            self.mock_command(command, body)
        for platform in ("Darwin", "Linux"):
            self.mock_command("uname", f"print({platform!r})\n")
            for scope in ([], ["--system"], ["--all"]):
                for prune in ([], ["-d"]):
                    with self.subTest(platform=platform, scope=scope, prune=prune):
                        log.unlink(missing_ok=True)
                        result = self.run_hey("gc", *scope, *prune)
                        self.assertEqual(result.returncode, 0, result.stderr)
                        commands = [json.loads(line) for line in log.read_text().splitlines()]
                        system = bool(scope)
                        expected = []
                        if prune:
                            if system:
                                expected.append(["sudo", "nix-env", "--delete-generations",
                                                 "--profile", "/nix/var/nix/profiles/system", "old"])
                                if platform == "Linux":
                                    expected.append(["sudo", "/nix/var/nix/profiles/system/bin/switch-to-configuration", "boot"])
                            if scope != ["--system"]:
                                expected.append(["nix-env", "--delete-generations", "--profile",
                                                 str(self.root / "state/nix/profiles/profile"), "old"])
                        expected.append((["sudo"] if system else []) + ["nix-store", "--gc"])
                        if system:
                            expected.append(["nix-store", "--optimise"])
                        self.assertEqual(commands, expected)
        self.env["NIXI_FAIL_PRUNE"] = "1"
        log.unlink()
        result = self.run_hey("gc", "--all", "-d")
        self.assertEqual(result.returncode, 7, result.stderr)
        self.assertEqual(len(log.read_text().splitlines()), 1)

    def test_generation_removal_refreshes_boot_and_propagates_failures(self):
        self.isolate_home()
        profiles = self.root / "profiles"
        profiles.mkdir()
        for number in (1, 2):
            (profiles / f"system-{number}-link").mkdir()
        profile = profiles / "system"
        profile.symlink_to("system-2-link")
        log = self.root / "commands.jsonl"
        body = f'''import json, os, sys
from pathlib import Path
command = [Path(sys.argv[0]).name, *sys.argv[1:]]
with Path({str(log)!r}).open("a") as output:
    output.write(json.dumps(command) + "\\n")
if "nix-env" in command: sys.exit(int(os.getenv("FAIL_DELETE", "0")))
if command[-1] == "boot": sys.exit(int(os.getenv("FAIL_BOOT", "0")))
'''
        self.mock_command("sudo", body)
        self.mock_command("nix-env", body)
        # Exercise the actual command's removal function with a synthetic
        # system profile; no test reads or alters the live system profile.
        script = f'''
(use hey)
(def scope (dofile {json.dumps(str(ROOT / "bin/hey.d/profile.janet"))}))
(import hey/system)
(defn fixture [&]
  (if (= "1" (os/getenv "EMPTY_PLAN"))
    (system/delete-generations {json.dumps(str(profile))} [] false)
    ((get-in scope ['remove-generations :value]) {json.dumps(str(profile))}
      ["1"] (= "1" (os/getenv "USER_PROFILE")))))
(defn main [_ & args] (dispatch [:fixture {{:cmd fixture}}] ;args))
'''
        driver = self.root / "profile-fixture.janet"
        driver.write_text(script)
        environment = self.env | {
            "PATH": self.env["DOTFILES_BIN"] + os.pathsep + self.env["PATH"],
            "JANET_PATH": str(ROOT / "vendor/janet") + os.pathsep + self.env.get("JANET_PATH", "")
                          + os.pathsep + str(ROOT / "runtime"),
        }
        for platform, user, delete_failure, boot_failure, empty in (
                ("Linux", False, 0, 0, False), ("Darwin", False, 0, 0, False),
                ("Linux", True, 0, 0, False), ("Linux", False, 7, 0, False),
                ("Linux", False, 0, 8, False), ("Linux", False, 0, 0, True)):
            with self.subTest(platform=platform, user=user, empty=empty,
                              delete_failure=delete_failure, boot_failure=boot_failure):
                self.mock_command("uname", f"print({platform!r})\n")
                log.unlink(missing_ok=True)
                result = subprocess.run(["janet", str(driver), "fixture"], cwd=self.consumer,
                    env=environment | {"FAIL_DELETE": str(delete_failure), "FAIL_BOOT": str(boot_failure),
                                       "USER_PROFILE": "1" if user else "0", "EMPTY_PLAN": "1" if empty else "0"},
                    text=True, capture_output=True, timeout=15)
                self.assertEqual(result.returncode, delete_failure or boot_failure, result.stderr)
                calls = [json.loads(line) for line in log.read_text().splitlines()]
                expected = [] if empty else [([] if user else ["sudo"]) +
                    ["nix-env", "--delete-generations", "--profile", str(profile), "1"]]
                if platform == "Linux" and not user and not delete_failure:
                    expected.append(["sudo", str(profile / "bin/switch-to-configuration"), "boot"])
                self.assertEqual(calls, expected)
                self.assertTrue((profiles / "system-1-link").is_dir())
                self.assertFalse((self.root / "runtime/hey/profile-rm.lock").exists())

    def test_gc_stops_before_collection_if_boot_refresh_fails(self):
        self.isolate_home()
        log = self.root / "commands.jsonl"
        body = f'''import json, sys
from pathlib import Path
with Path({str(log)!r}).open("a") as output:
    output.write(json.dumps([Path(sys.argv[0]).name, *sys.argv[1:]]) + "\\n")
if sys.argv[-1] == "boot": sys.exit(8)
'''
        for command in ("sudo", "nix-env", "nix-store"):
            self.mock_command(command, body)
        self.mock_command("uname", "print('Linux')\n")
        result = self.run_hey("gc", "--all", "-d")
        self.assertEqual(result.returncode, 8, result.stderr)
        calls = [json.loads(line) for line in log.read_text().splitlines()]
        self.assertEqual(len(calls), 2)
        self.assertEqual(calls[1][-1], "boot")
        self.assertNotIn("--gc", log.read_text())

    @unittest.skipUnless(shutil.which("jq"), "jq is not available")
    def test_vm_plist_replacement_preserves_original_on_failure(self):
        original = {"name": "fixture", "nested": {"keep": 1, "change": "old"}}
        destination = self.root / "VM with spaces.utm/config.plist"
        destination.parent.mkdir()
        self.env["NIXI_TEST_PLIST"] = str(destination)
        self.env["JANET_PATH"] = str(ROOT / "runtime") + os.pathsep + self.env.get("JANET_PATH", "")
        self.mock_command("nix", '''import os, sys
if os.environ.get("NIXI_FAIL_PHASE") == "nix": sys.exit(7)
assert "\\n" in sys.argv[-1], "Nix expression newlines must survive"
print('{"nested":{"change":"new"}}')
''')
        self.mock_command("jq", f'''import os, sys
if os.environ.get("NIXI_FAIL_PHASE") == "jq": sys.exit(7)
os.execv({shutil.which("jq")!r}, ["jq", *sys.argv[1:]])
''')
        directory = self.mock_command("plutil", '''import json, os, plistlib, sys
from pathlib import Path
args = sys.argv[1:]
destination = Path(os.environ["NIXI_TEST_PLIST"])
# Every pre-commit step must see the original live plist, including its mode.
assert plistlib.loads(destination.read_bytes())["nested"]["change"] == "old"
assert destination.stat().st_mode & 0o777 == 0o640
phase = args[1] if args[0] == "-convert" else "lint"
if os.environ.get("NIXI_FAIL_PHASE") == phase: sys.exit(7)
if phase == "json":
    Path(args[3]).write_text(json.dumps(plistlib.loads(Path(args[4]).read_bytes())))
elif phase == "xml1":
    file = Path(args[2])
    file.write_bytes(plistlib.dumps(json.loads(file.read_text())))
else:
    plistlib.loads(Path(args[1]).read_bytes())
''')
        self.env["PATH"] = str(directory) + os.pathsep + self.env["PATH"]
        script = '(use hey/vm) (vm/update-plist (os/getenv "NIXI_TEST_PLIST") "{ # comment\\n nested.change = \\"new\\"; }")'
        for encoding in (plistlib.FMT_BINARY, plistlib.FMT_XML):
            for phase in ("nix", "json", "jq", "xml1", "lint", "success"):
                with self.subTest(encoding=encoding, phase=phase):
                    before = plistlib.dumps(original, fmt=encoding)
                    destination.write_bytes(before)
                    destination.chmod(0o640)
                    self.env["NIXI_FAIL_PHASE"] = phase
                    result = subprocess.run(["janet", "-e", script], env=self.env,
                                            text=True, capture_output=True, timeout=30)
                    if phase == "success":
                        self.assertEqual(result.returncode, 0, result.stderr)
                        self.assertEqual(plistlib.loads(destination.read_bytes()),
                                         {"name": "fixture", "nested": {"keep": 1, "change": "new"}})
                    else:
                        self.assertNotEqual(result.returncode, 0)
                        self.assertIn("exit code(s)", result.stderr)
                        self.assertEqual(destination.read_bytes(), before)
                    self.assertEqual(destination.stat().st_mode & 0o777, 0o640)
                    self.assertEqual(list(destination.parent.iterdir()), [destination])
        saved = destination.with_name("original.plist")
        destination.rename(saved)
        destination.symlink_to(saved.name)
        result = subprocess.run(["janet", "-e", script], env=self.env,
                                text=True, capture_output=True, timeout=30)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Expected a regular VM configuration file", result.stderr)
        self.assertTrue(destination.is_symlink())

    def test_external_consumer_paths_and_sync(self):
        result = self.run_hey("path", "framework")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), str(ROOT))
        result = self.run_hey("-!", "sync")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(str(self.consumer) + "#laptop", result.stdout)
        self.assertFalse((self.consumer / "bin").exists())
        self.assertFalse((self.consumer / "nixi").exists())

    def test_flat_or_inline_host_does_not_require_hosts_directory(self):
        result = self.run_hey("doctor", "env")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_system_rollback_dry_run_activates_and_verifies(self):
        result = self.run_hey("-!", "sync", "rollback", "12")
        self.assertEqual(result.returncode, 0, result.stderr)
        if os.uname().sysname == "Darwin":
            self.assertIn("darwin-rebuild --switch-generation 12", result.stdout)
            self.assertNotIn("switch-to-configuration", result.stdout)
        else:
            self.assertIn("nix-env --switch-generation 12", result.stdout)
            self.assertIn("switch-to-configuration switch", result.stdout)
        self.assertIn("verify /run/current-system", result.stdout)

    def test_project_flake_fallback(self):
        for action in ("check", "ci"):
            result = self.run_hey("-!", "project", action)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("DRYRUN: nix flake check", result.stdout)
            self.assertNotIn("git status", result.stdout)
        result = self.run_hey("project", "test")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("justfile test recipe", result.stderr)

    def test_project_tests_are_not_hidden_by_flake(self):
        (self.consumer / "Cargo.toml").write_text('[package]\nname="fixture"\nversion="0.1.0"\n')
        self.mock_command("cargo", "import sys\nprint('native-tests-ran')\nsys.exit(42)\n")
        self.mock_command("nix", "raise AssertionError('must not replace application tests')\n")
        result = self.run_hey("project", "test")
        self.assertEqual(result.returncode, 42, result.stderr)
        self.assertIn("native-tests-ran", result.stdout)

    def test_project_doctor_requires_core_tools_but_not_optional_tools(self):
        self.isolate_home()
        directory = self.mock_command("git", "raise SystemExit(1)\n")
        generated_path = self.root / "data/hey/path"
        generated_path.parent.mkdir(parents=True)
        generated_path.write_text(str(directory))
        for name in ("dirname", "janet", "uname", "sh", "env"):
            executable = shutil.which(name)
            self.assertIsNotNone(executable, name)
            (directory / name).symlink_to(executable)
        self.env["PATH"] = str(directory)
        result = self.run_hey("project", "doctor")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("Project requirements missing: nix", result.stderr)
        self.assertNotIn("project doctor complete", result.stdout)
        self.mock_command("nix", "raise AssertionError('doctor must not execute nix')\n")
        (self.consumer / "Cargo.toml").write_text('[package]\nname="fixture"\n')
        result = self.run_hey("project", "doctor")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("Project requirements missing: cargo", result.stderr)
        self.mock_command("cargo", "raise AssertionError('doctor must not execute cargo')\n")
        result = self.run_hey("project", "doctor")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("rust-analyzer command is missing", result.stderr)
        self.assertIn("project doctor complete", result.stdout)

    def test_user_rollback_holds_shared_profile_lock(self):
        self.isolate_home()
        profiles = self.root / "state/nix/profiles"
        profiles.mkdir(parents=True)
        for number in (1, 2):
            (profiles / f"profile-{number}-link").mkdir()
        (profiles / "profile").symlink_to("profile-2-link")
        lock = self.root / "runtime/hey/profile-rm.lock"
        self.mock_command("nix-env", f'''from pathlib import Path
assert Path({str(lock)!r}).is_dir(), "mutation must hold the shared lock"
print("locked-switch")
''')
        result = self.run_hey("profile", "rollback", "--user")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("locked-switch", result.stdout)
        self.assertFalse(lock.exists())

    def test_sync_and_system_rollback_release_shared_lock_on_failure(self):
        self.isolate_home()
        lock = self.root / "runtime/hey/profile-rm.lock"
        self.mock_command("sudo", f'''from pathlib import Path
assert Path({str(lock)!r}).is_dir(), "mutation must hold the shared lock"
raise SystemExit(7)
''')
        for args in (("sync", "--flake", str(self.consumer) + "#laptop"),
                     ("sync", "rollback", "12")):
            with self.subTest(args=args):
                result = self.run_hey(*args)
                self.assertEqual(result.returncode, 7, result.stderr)
                self.assertFalse(lock.exists())

    def test_unknown_project_fails(self):
        project = self.root / "unknown"
        project.mkdir()
        (project / "package.json").write_text("{}\n")
        for action in ("check", "test", "profile", "ci"):
            result = self.run_hey("project", action, cwd=project)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("No project", result.stderr)

    @unittest.skipUnless(shutil.which("just"), "just is not available")
    def test_project_recipe_precedence_and_failure_propagation(self):
        # Keep flake.nix: explicit recipes take precedence over its fallback.
        (self.consumer / "justfile").write_text("check:\n    @exit 7\n\ntest:\n    @echo recipe-ran\n")
        result = self.run_hey("project", "check")
        self.assertEqual(result.returncode, 7, result.stderr)
        result = self.run_hey("project", "test")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("recipe-ran", result.stdout)

    def test_nested_project_uses_nearest_project_root(self):
        subprocess.run(["git", "init", "--quiet", str(self.consumer)], check=True)
        project = self.consumer / "nested"
        project.mkdir()
        (project / "Cargo.toml").write_text('[package]\nname="fixture"\nversion="0.1.0"\n')
        source = project / "src"
        source.mkdir()
        result = self.run_hey("-!", "project", "check", cwd=source)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("cargo check", result.stdout)
        self.assertNotIn("nix flake check", result.stdout)

    def test_project_discovery_without_git_and_at_filesystem_root(self):
        self.isolate_home()
        source = self.consumer / "src/deep"
        source.mkdir(parents=True)
        result = self.run_hey("-!", "project", "check", cwd=source)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("DRYRUN: nix flake check", result.stdout)
        for cwd in (self.root, Path("/")):
            result = self.run_hey("project", "status", cwd=cwd)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("root: " + str(cwd.resolve()) + "\n", result.stdout)

    def test_project_discovery_honors_git_boundaries_without_markers(self):
        self.isolate_home()
        # The parent flake must not leak into a nested, independent repository.
        project = self.consumer / "independent"
        source = project / "src/deep"
        source.mkdir(parents=True)
        subprocess.run(["git", "init", "--quiet", str(project)], check=True)
        result = self.run_hey("project", "status", cwd=source)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("root: " + str(project.resolve()) + "\n", result.stdout)
        result = self.run_hey("-!", "project", "check", cwd=source)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("No project check command configured", result.stderr)

    def test_project_discovery_recognizes_shell_gradle_and_service_files(self):
        self.isolate_home()
        self.env["SHELL"] = "/bin/sh"
        for in_git in (False, True):
            if in_git:
                subprocess.run(["git", "init", "--quiet", str(self.consumer)], check=True)
            for marker in (".envrc", "gradlew", "process-compose.yaml", "process-compose.yml"):
                project = self.consumer / (str(in_git) + marker)
                source = project / "src/deep"
                source.mkdir(parents=True)
                (project / marker).write_text("# fixture\n")
                for cwd in (project, source):
                    with self.subTest(in_git=in_git, marker=marker, cwd=cwd):
                        result = self.run_hey("project", "status", cwd=cwd)
                        self.assertEqual(result.returncode, 0, result.stderr)
                        self.assertIn("root: " + str(project.resolve()) + "\n", result.stdout)
                        if marker == ".envrc":
                            result = self.run_hey("-!", "project", "shell", cwd=cwd)
                            self.assertEqual(result.returncode, 0, result.stderr)
                            self.assertIn("direnv exec " + str(project.resolve()), result.stdout)
                        elif marker == "gradlew":
                            result = self.run_hey("-!", "project", "check", cwd=cwd)
                            self.assertEqual(result.returncode, 0, result.stderr)
                            self.assertIn("./gradlew test", result.stdout)
                        else:
                            for action in ("up", "down", "logs", "services"):
                                result = self.run_hey("-!", "project", action, cwd=cwd)
                                self.assertEqual(result.returncode, 0, result.stderr)
                                self.assertIn(str(project.resolve() / ".nixi/process-compose.sock"), result.stdout)
                                if action == "up":
                                    self.assertIn("--config " + str((project / marker).resolve()), result.stdout)
                            self.assertFalse((project / ".nixi").exists())

    @unittest.skipUnless(shutil.which("just"), "just is not available")
    def test_missing_just_recipe_uses_flake_fallback(self):
        (self.consumer / "justfile").write_text("hello:\n    @echo hello\n")
        for action in ("check", "ci"):
            result = self.run_hey("-!", "project", action)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("DRYRUN: nix flake check", result.stdout)
        result = self.run_hey("-!", "project", "test")
        self.assertNotEqual(result.returncode, 0)

    def test_eks_duplicate_names_require_explicit_key(self):
        self.configure_eks(eksClusters={
            "staging": {"name": "shared", "profile": "stage", "bastion": "stage-jump"},
            "production": {"name": "shared", "profile": "prod", "bastion": "prod-jump"},
        })
        for command in ("env", "shell", "kubeconfig", "open"):
            result = self.run_hey("-!", "eks", command, "shared")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("use an explicit key: production, staging", result.stderr)
            self.assertNotIn("DRYRUN:", result.stdout)
        self.configure_eks(eksClusters={
            "shared": {"name": "other", "profile": "exact"},
            "production": {"name": "shared", "profile": "prod"},
        })
        result = self.run_hey("eks", "env", "shared")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("AWS_PROFILE='exact'", result.stdout)

    def test_eks_environment_switch_clears_optional_values(self):
        self.configure_eks(eksClusters={
            "first": {"name": "first", "profile": "first", "region": "us-east-1", "namespace": "production"},
            "second": {"name": "second", "profile": "second", "region": None, "namespace": None},
        })
        first = self.run_hey_bytes("eks", "env", "first")
        second = self.run_hey_bytes("eks", "env", "second")
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertNotIn(b'\r', first.stdout + second.stdout)
        script = first.stdout + second.stdout + b'\n[ "$AWS_PROFILE" = second ] && [ "$EKS_CLUSTER" = second ] && [ "${AWS_REGION+x}" != x ] && [ "${AWS_DEFAULT_REGION+x}" != x ] && [ "${KUBE_NAMESPACE+x}" != x ]\n'
        for shell in ("sh", "bash", "zsh"):
            if shutil.which(shell):
                result = subprocess.run([shell, "-f", "-e"], input=script, env=self.env,
                                        capture_output=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr)
        self.env.update(AWS_REGION="us-east-1", AWS_DEFAULT_REGION="us-east-1", KUBE_NAMESPACE="production")
        self.mock_command("aws", "import os\nassert 'AWS_REGION' not in os.environ\nassert 'AWS_DEFAULT_REGION' not in os.environ\n")
        shell = self.mock_command("fixture-shell", "import os\nassert os.environ['AWS_PROFILE'] == 'second'\nassert os.environ['EKS_CLUSTER'] == 'second'\nassert all(k not in os.environ for k in ('AWS_REGION', 'AWS_DEFAULT_REGION', 'KUBE_NAMESPACE'))\n") / "fixture-shell"
        self.env["SHELL"] = str(shell)
        result = self.run_hey("eks", "shell", "second")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_eks_use_stdout_is_only_shell_code(self):
        self.configure_eks(eksClusters={"fixture": {"name": "fixture", "profile": "work's profile"}})
        self.mock_command("aws", "pass\n")
        self.mock_command("kubectl", "pass\n")
        result = self.run_hey_bytes("eks", "use", "fixture")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn(b'\r', result.stdout)
        self.assertNotIn(b'\x1b', result.stdout)
        self.assertIn(b"Kubernetes context is selected", result.stderr)
        for line in result.stdout.splitlines():
            self.assertTrue(line.startswith((b"export ", b"unset ")), line)
        script = result.stdout + b'\n[ "$AWS_PROFILE" = "work\x27s profile" ]\n'
        result = subprocess.run(["sh", "-e"], input=script, env=self.env, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_eks_bastion_env_keeps_routing_on_stderr(self):
        self.configure_eks(eksClusters={"fixture": {
            "name": "fixture", "profile": "work", "bastion": "jump"}})
        self.mock_command("utmctl", 'print("198.51.100.2")\n')
        self.mock_command("ssh", '''import sys
assert "StrictHostKeyChecking=yes" in sys.argv
assert "-t" not in sys.argv
print("export AWS_PROFILE='remote'")
''')
        result = self.run_hey_bytes("eks", "env", "fixture")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, b"export AWS_PROFILE='remote'\n")
        self.assertIn(b"routing EKS command", result.stderr)

    def test_pull_exclusions_are_subtracted_after_inclusions(self):
        self.mock_command("nix", '''import json, sys
if "metadata" in sys.argv:
    print(json.dumps({"locks": {"root": "consumer", "nodes": {"consumer": {"inputs": {"nixpkgs": "n", "other": "o", "third": "t"}}}}}))
else:
    print("SELECTED:" + json.dumps(sys.argv[1:]))
''')
        for patterns, expected in ((["*", "!nixpkgs"], ["other", "third"]),
                                   (["!nixpkgs", "*"], ["other", "third"]),
                                   (["!nixpkgs", "!third"], ["other"]),
                                   (["other", "!third"], ["other"])):
            result = self.run_hey("pull", *patterns)
            self.assertEqual(result.returncode, 0, result.stderr)
            selected = next(line for line in result.stdout.splitlines() if line.startswith("SELECTED:"))
            args = json.loads(selected.removeprefix("SELECTED:"))
            self.assertEqual(args[args.index("--impure") + 1:], expected)
        for patterns in (["*", "!*"], ["!"], ["missing"]):
            result = self.run_hey("pull", *patterns)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn("SELECTED:", result.stdout)

    def test_process_dry_run_does_not_create_state(self):
        (self.consumer / "process-compose.yaml").write_text("version: '0.5'\nprocesses: {}\n")
        result = self.run_hey("-!", "project", "up")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.consumer / ".nixi").exists())

    def test_multi_generation_removal_dry_run_does_not_lock(self):
        profiles = self.root / "state/nix/profiles"
        profiles.mkdir(parents=True)
        for number in (1, 2, 3):
            (profiles / f"profile-{number}-link").mkdir()
        (profiles / "profile").symlink_to("profile-3-link")
        result = self.run_hey("-!", "profile", "rm", "--user", "-1", "-2")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.count("--delete-generations"), 1)
        self.assertIn(" 2 1", result.stdout)
        self.assertFalse((self.root / "runtime").exists())

    def test_local_retention_handles_gaps_rollback_and_dry_run(self):
        profiles = self.root / "state/nix/profiles"
        profiles.mkdir(parents=True)
        for number in (1, 3, 7, 12):
            (profiles / f"profile-{number}-link").mkdir()
        (profiles / "profile").symlink_to("profile-3-link")
        (profiles / "profile-invalid-link").mkdir()
        log = self.root / "deleted.json"
        self.mock_command("nix-env", f'''import json, sys
from pathlib import Path
Path({str(log)!r}).write_text(json.dumps(sys.argv[1:]))
''')
        result = self.run_hey("-!", "profile", "prune", "--user", "--keep-generations", "2")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Keep generations: 3, 12", result.stdout)
        self.assertIn("Delete generations: 1, 7", result.stdout)
        self.assertFalse(log.exists())
        self.assertFalse((self.root / "runtime").exists())
        result = self.run_hey("profile", "prune", "--user", "--keep-generations", "2")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(log.read_text()),
                         ["--delete-generations", "--profile", str(profiles / "profile"), "1", "7"])
        log.unlink()
        for count in ("4", "10"):
            result = self.run_hey("profile", "prune", "--user", "--keep-generations", count)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("Delete generations: none", result.stdout)
            self.assertFalse(log.exists())
        for count in ("0", "-1", "1.5", "nan", "inf", "2147483648"):
            result = self.run_hey("profile", "prune", "--user", "--keep-generations", count)
            self.assertNotEqual(result.returncode, 0, count)
            self.assertFalse(log.exists())
        for args in (("prune",), ("ls", "--keep-generations", "2"),
                     ("prune", "--keep-generations", "2", "unexpected")):
            result = self.run_hey("profile", *args, "--user")
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(log.exists())
        (profiles / "profile").unlink()
        result = self.run_hey("profile", "prune", "--user", "--keep-generations", "2")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(log.exists())

    def ip_discovery_fixture(self):
        self.diagnostic_fixture()
        self.mock_command("utmctl", "raise SystemExit(1)\n")
        self.mock_command("arp", "pass\n")
        self.mock_command("md5", "print('0123456789abcdef0123456789abcdef')\n")
        self.mock_command("osascript", "import sys\nprint('bridge0' if 'host interface' in sys.argv[-1] else '02:01:23:45:67:89')\n")
        self.mock_command("ipconfig", "print('192.0.2.7')\n")
        log = self.root / "ping-log"
        self.mock_command("ping", f'''import os, signal, time
fd = os.open({str(log)!r}, os.O_CREAT | os.O_WRONLY | os.O_APPEND, 0o600)
def done(*args):
    os.write(fd, ("end " + str(os.getpid()) + "\\n").encode())
    raise SystemExit(0)
signal.signal(signal.SIGTERM, done)
signal.signal(signal.SIGALRM, done)
signal.alarm(3)
os.write(fd, ("start " + str(os.getpid()) + "\\n").encode())
time.sleep(3)
done()
''')
        return log

    def test_ip_discovery_is_passive_by_default_and_dry_run_is_inert(self):
        log = self.ip_discovery_fixture()
        result = self.run_hey("utm", "ip", "fixture", "--wait", "0.2")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(log.exists())
        self.assertIn("within 0.2 seconds", result.stderr)
        for args in (("-!", "utm", "ip", "fixture", "--scan"),
                     ("-!", "utm", "ip", "fixture")):
            result = self.run_hey(*args)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("DRYRUN: resolve IP", result.stdout)
            self.assertFalse(log.exists())
        result = self.run_hey("utm", "ls", "--scan")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(log.exists())

    def test_ip_discovery_scan_has_bounded_fanout_and_shared_deadline(self):
        log = self.ip_discovery_fixture()
        start = time.monotonic()
        result = self.run_hey("utm", "ip", "fixture", "--scan", "--wait", "4")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("within 4 seconds", result.stderr)
        self.assertLess(time.monotonic() - start, 6)
        # Every mock emits atomic start/end records, including on cancellation.
        # This checks concurrent processes rather than depending on CPU speed.
        active, peak = set(), 0
        for line in log.read_text().splitlines():
            event, pid = line.split()
            if event == "start":
                active.add(pid)
                peak = max(peak, len(active))
            else:
                active.remove(pid)
        self.assertGreater(peak, 0)
        self.assertLessEqual(peak, 8)
        self.assertEqual(active, set())

    def test_ip_discovery_slow_probe_cannot_restart_the_deadline(self):
        log = self.ip_discovery_fixture()
        self.mock_command("utmctl", "import signal, time\nsignal.alarm(3)\ntime.sleep(3)\n")
        start = time.monotonic()
        result = self.run_hey("utm", "ip", "fixture", "--scan", "--wait", "0.2")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("within 0.2 seconds", result.stderr)
        self.assertLess(time.monotonic() - start, 2)
        self.assertFalse(log.exists())

    def test_profile_rejects_removed_reload_flag(self):
        profiles = self.root / "state/nix/profiles"
        profiles.mkdir(parents=True)
        for number in (1, 2):
            (profiles / f"profile-{number}-link").mkdir()
        (profiles / "profile").symlink_to("profile-2-link")
        for action in ("ls", "current", "previous", "rollback", "rm", "diff"):
            args = ["1"] if action == "rm" else []
            result = self.run_hey("-!", "profile", action, "--user", "-r", *args)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn("DRYRUN: nix-env", result.stdout)

    def test_multi_digit_relative_generation_is_one_operand(self):
        profiles = self.root / "state/nix/profiles"
        profiles.mkdir(parents=True)
        for number in range(1, 21):
            (profiles / f"profile-{number}-link").mkdir()
        (profiles / "profile").symlink_to("profile-20-link")
        for operands in (["-12"], ["--", "-12"]):
            result = self.run_hey("-!", "profile", "rm", "--user", *operands)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.count("--delete-generations"), 1)
            self.assertIn(str(profiles / "profile") + " 8", result.stdout)

    def test_removal_validates_all_operands_before_mutation(self):
        profiles = self.root / "state/nix/profiles"
        profiles.mkdir(parents=True)
        for number in range(1, 5):
            (profiles / f"profile-{number}-link").mkdir()
        (profiles / "profile").symlink_to("profile-4-link")
        mock_bin = self.root / "mock-bin"
        mock_bin.mkdir()
        self.env["DOTFILES_BIN"] = str(mock_bin)
        log = self.root / "deleted.json"
        executable = mock_bin / "nix-env"
        executable.write_text(f"#!{sys.executable}\nimport json, sys\nfrom pathlib import Path\n"
                              f"Path({str(log)!r}).write_text(json.dumps(sys.argv[1:]))\n")
        executable.chmod(0o755)
        for invalid in ("bogus", "999", "-99", "1.5", "0", "4"):
            result = self.run_hey("profile", "rm", "--user", "1", invalid)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(log.exists(), result.stdout + result.stderr)
        result = self.run_hey("profile", "rm", "--user", "-1", "-2", "-1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(log.read_text()),
                         ["--delete-generations", "--profile", str(profiles / "profile"), "3", "2"])

    def test_linux_ip_uses_kernel_resolved_source_without_network_traffic(self):
        self.isolate_home()
        log = self.root / "ip-argv"
        self.mock_command("uname", 'print("Linux")\n')
        self.mock_command("ip", f'''import json, sys
from pathlib import Path
args = sys.argv[1:]
Path({str(log)!r}).write_text(json.dumps(args))
if args == ["-j", "-4", "route", "get", "1.1.1.1"]:
    print(json.dumps([{{"dst": "1.1.1.1", "gateway": "192.0.2.1",
                       "dev": "eth0", "prefsrc": "192.0.2.23", "flags": []}}]))
else:
    # A perfectly valid default route need not declare a preferred source.
    print("default via 192.0.2.1 dev eth0 proto dhcp metric 100")
''')
        result = self.run_hey("info", "-r", "ip")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout.strip(), "192.0.2.23")
        self.assertEqual(json.loads(log.read_text()), ["-j", "-4", "route", "get", "1.1.1.1"])
        log.unlink()
        self.mock_command("uname", 'raise AssertionError("dry-run executed uname")\n')
        result = self.run_hey("-!", "info", "ip")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("ip -j -4 route get 1.1.1.1", result.stdout)
        self.assertFalse(log.exists())

    def test_linux_ip_rejects_failed_or_unusable_route_lookups(self):
        self.isolate_home()
        self.mock_command("uname", 'print("Linux")\n')
        for route in ([], [{"dev": "eth0"}], [{"prefsrc": ""}], [{"prefsrc": None}]):
            with self.subTest(route=route):
                self.mock_command("ip", f"print({json.dumps(route)!r})\n")
                result = self.run_hey("info", "ip")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Could not determine source IPv4 address", result.stderr)
        self.mock_command("ip", 'import sys\nprint("Network is unreachable", file=sys.stderr)\nsys.exit(2)\n')
        result = self.run_hey("info", "ip")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Network is unreachable", result.stderr)

    def test_darwin_and_wan_ip_discovery_are_unchanged(self):
        self.isolate_home()
        self.mock_command("uname", 'print("Darwin")\n')
        self.mock_command("route", '''import sys
assert sys.argv[1:] == ["-n", "get", "default"]
print("   route to: default\\n   interface: en7")
''')
        self.mock_command("ipconfig", '''import sys
assert sys.argv[1:] == ["getifaddr", "en7"]
print("192.0.2.24")
''')
        result = self.run_hey("info", "-r", "ip")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "192.0.2.24")
        self.mock_command("uname", 'raise AssertionError("WAN discovery executed uname")\n')
        self.mock_command("dig", '''import sys
assert sys.argv[1:] == ["+short", "myip.opendns.com", "@resolver1.opendns.com"]
print("198.51.100.24")
''')
        result = self.run_hey("info", "-r", "ip", "-w")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "198.51.100.24")

    @unittest.skipUnless(shutil.which("nix"), "nix is not available")
    def test_real_nix_quoted_host_check_and_image_names(self):
        self.isolate_home()
        self.isolate_nix()
        self.env["HEY_NIX_USE_NOM"] = "0"
        (self.consumer / "flake.nix").write_text(r'''{
  outputs = _: let leaf.drvPath = "/nix/store/fixture.drv"; in {
    darwinConfigurations."node.example".system = leaf;
    nixosConfigurations."vm.example".config.system.build = {
      toplevel = leaf;
      images = { qemu-efi = leaf; "image.v2" = leaf; };
    };
    checks.${builtins.currentSystem} = {
      "check.with.dot" = leaf;
      "check with spaces" = leaf;
      "back\\slash" = leaf;
    };
  };
}
''')
        real_nix = shutil.which("nix")
        log = self.root / "build-targets"
        self.mock_command("nix", f'''import json, os, sys
from pathlib import Path
args = sys.argv[1:]
if args[0] == "build":
    # Select the actual output with Nix, but do not build or activate anything.
    target = args[-1]
    with Path({str(log)!r}).open("a") as output:
        output.write(json.dumps(target) + "\\n")
    args = ["eval", "--impure", "--raw", "--no-write-lock-file", target + ".drvPath"]
os.execv({real_nix!r}, [{real_nix!r}, *args])
''')
        result = self.run_hey("host", "list")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("node.example", result.stdout)
        self.assertIn("vm.example", result.stdout)
        for arguments in [("check", "eval"), ("check", "eval", "node.example"),
                          ("check", "eval", "vm.example"), ("check", "all"),
                          ("check", "build", "node.example"),
                          ("check", "build", "vm.example"),
                          ("check", "image", "vm.example"),
                          ("image", "build", "vm.example", "image.v2")]:
            with self.subTest(arguments=arguments):
                result = self.run_hey(*arguments)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        result = self.run_hey("image", "list", "vm.example")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ["image.v2", "qemu-efi"])
        targets = [json.loads(line).split("#", 1)[1] for line in log.read_text().splitlines()]
        self.assertIn('darwinConfigurations."node.example".system', targets)
        self.assertIn('nixosConfigurations."vm.example".config.system.build.toplevel', targets)
        self.assertIn('nixosConfigurations."vm.example".config.system.build.images."image.v2"', targets)
        for check in ('"check.with.dot"', '"check with spaces"', '"back\\slash"'):
            self.assertTrue(any(target.startswith("checks.") and target.endswith("." + check)
                                for target in targets), targets)
        result = self.run_hey("-!", "image", "list", "vm.example")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('nixosConfigurations."vm.example".config.system.build.images', result.stdout)
        self.assertFalse((self.consumer / "flake.lock").exists())

    def test_consumer_checks_do_not_require_framework_outputs(self):
        mock_bin = self.root / "mock-bin"
        mock_bin.mkdir()
        self.env["DOTFILES_BIN"] = str(mock_bin)
        executable = mock_bin / "nix"
        # No modules, checks or Darwin hosts: a normal Linux-only consumer.
        executable.write_text(f"#!{sys.executable}\n" + '''import json, sys
args = sys.argv[1:]
if "builtins.currentSystem" in args:
    print("x86_64-linux")
elif "attrPath" in args:
    path = json.loads(args[args.index("attrPath") + 1])
    assert path in [["darwinConfigurations"], ["nixosConfigurations"], ["checks", "x86_64-linux"]], path
    print(json.dumps(["server"] if path == ["nixosConfigurations"] else []))
else:
    assert any(arg.endswith("#nixosConfigurations.server.config.system.build.toplevel.drvPath") for arg in args), args
    print("/nix/store/fixture.drv")
''')
        executable.chmod(0o755)
        for action in ("eval", "all"):
            result = self.run_hey("check", action)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("server", result.stdout)

    @unittest.skipUnless(shutil.which("nix"), "nix is not available")
    def test_real_nix_consumer_without_optional_outputs(self):
        # Use an isolated local store: no daemon, registry, network or real
        # profile. In particular, this catches Nix's function auto-call rules.
        self.env["NIX_REMOTE"] = str(self.root.resolve() / "nix-store")
        self.env["DOTFILES_HOME"] = str(self.consumer.resolve())
        self.env["NIX_CONFIG"] = "experimental-features = nix-command flakes\n"
        (self.consumer / "flake.nix").write_text('''{
  outputs = _: {
    nixosConfigurations.server.config.system.build.toplevel.drvPath = "/nix/store/fixture.drv";
  };
}
''')
        for action in ("eval", "all"):
            result = self.run_hey("check", action)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("server", result.stdout)
        (self.consumer / "flake.nix").write_text('{ outputs = _: throw "fixture evaluation failure"; }\n')
        result = self.run_hey("check", "eval")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("fixture evaluation failure", result.stderr)

    def test_lock_serializes_processes_and_times_out_without_stealing(self):
        self.env["JANET_PATH"] = ":".join([str(ROOT / "runtime"), str(ROOT / "vendor/janet"),
                                           self.env.get("JANET_PATH", "")])
        lock = self.root / "fixture.lock"
        acquire = f'(import hey/lock) (def release (lock/acquire {json.dumps(str(lock))} 0))'
        with subprocess.Popen(["janet", "-e", acquire +
                               ' (print "locked") (flush) (file/read stdin :line) (release)'],
                              env=self.env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, text=True) as owner:
            try:
                self.assertTrue(select.select([owner.stdout], [], [], 5)[0], "lock acquisition stalled")
                self.assertEqual(owner.stdout.readline().strip(), "locked")
                contender = subprocess.run(["janet", "-e", acquire + " (release)"], env=self.env,
                                           capture_output=True, text=True, timeout=5)
                self.assertNotEqual(contender.returncode, 0)
                self.assertIn("Timed out waiting for lock", contender.stderr)
                self.assertTrue(lock.is_dir())
                _, error = owner.communicate("release\n", timeout=5)
                self.assertEqual(owner.returncode, 0, error)
            finally:
                if owner.poll() is None:
                    owner.terminate()
                    owner.communicate(timeout=5)
        self.assertFalse(lock.exists())
        contender = subprocess.run(["janet", "-e", acquire + " (release)"], env=self.env,
                                   capture_output=True, text=True, timeout=5)
        self.assertEqual(contender.returncode, 0, contender.stderr)

    def test_utm_rejects_unsupported_modes_before_any_deployment(self):
        for mode in ("test", "boot", "dry-activate", "invalid"):
            for dry_run in ([], ["-!"]):
                result = self.run_hey(*dry_run, "utm", "update", "fixture", "--mode", mode)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("supports only --mode switch", result.stderr)
                self.assertNotIn("nix build", result.stdout)
                self.assertFalse((self.root / "runtime").exists())

    def test_utm_switch_dry_run_keeps_trust_and_documents_persistence(self):
        result = self.run_hey("-!", "utm", "update", "fixture", "--mode", "switch")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("switch-to-configuration switch", result.stdout)
        self.assertIn("--set <toplevel>", result.stdout)
        self.assertIn("switch-to-configuration boot", result.stdout)
        self.assertNotIn("remove stale", result.stdout)

    def test_utm_user_defaults_and_retention_argument_validation(self):
        for flake in ([], ["--flake", ".#database"]):
            for user, expected in (([], "alice"), (["--user", "explicit"], "explicit")):
                result = self.run_hey("-!", "utm", "ssh", "database", *flake, *user)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(f"{expected}@<ip>", result.stdout)
        for command in ("update", "cleanup-generations"):
            for count in ("0", "-1", "1.5", "nope", "inf", "2147483648"):
                result = self.run_hey("-!", "utm", command, "database", "--keep-generations", count)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("expects a number" if count in ("nope", "inf") else "positive 32-bit integer", result.stderr)
                self.assertNotIn("DRYRUN", result.stdout)

    def utm_retention_fixture(self):
        self.isolate_home()
        log, info_file = self.root / "ssh-calls", self.root / "remote-info"
        current_file, next_info = self.root / "current-system", self.root / "next-info"
        current_file.write_text("/nix/store/fixture-nixos-system-review")
        self.env["HEY_NIX_USE_NOM"] = "0"
        self.mock_command("hey", "print('192.0.2.1')\n")
        self.mock_command("nix", "print('/nix/store/fixture-nixos-system-review')\n")
        self.mock_command("ssh", f'''import json, sys
from pathlib import Path
remote = sys.argv[-1]
with Path({str(log)!r}).open("a") as stream:
    stream.write(remote + "\\n")
if remote == "true": pass
elif remote.startswith("readlink -f"): print(Path({str(current_file)!r}).read_text())
elif "sshd -T -G" in remote: print("no")
elif "sudo -n -l" in remote: print("yes")
elif remote.startswith("cat"): print(Path({str(info_file)!r}).read_text())
elif remote == "switch":
    Path({str(current_file)!r}).write_text("/nix/store/fixture-nixos-system-review")
    Path({str(info_file)!r}).write_text(Path({str(next_info)!r}).read_text())
elif "--delete-generations" in remote or "--set" in remote or "switch-to-configuration" in remote or remote == "boot": pass
else: raise RuntimeError("Unexpected mock command: " + remote)
''')
        enabled = {"enable": True, "autoCleanGenerations": True, "keepGenerations": 9}
        return log, info_file, current_file, next_info, enabled

    def test_utm_retention_requires_affirmative_policy_and_honors_overrides(self):
        log, info_file, _, _, enabled = self.utm_retention_fixture()
        for profile, override, expected in (
            (None, None, None),
            (enabled | {"enable": False}, None, None),
            (enabled | {"autoCleanGenerations": False}, None, None),
            (enabled | {"autoCleanGenerations": False}, "5", None),
            (enabled, None, 9),
            (enabled | {"schemaVersion": 1}, None, 9),
            (enabled, "5", 5),
        ):
            with self.subTest(profile=profile, override=override):
                info_file.write_text(json.dumps({"profiles": {} if profile is None else {"vm-image": profile}}))
                log.write_text("")
                # This tests policy, not startup speed of the sandbox's Python.
                # Strict timing assertions live in the dedicated SSH wait test.
                args = ["utm", "update", "review", "--wait", "5"]
                if override: args += ["--keep-generations", override]
                result = self.run_hey(*args)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                calls = log.read_text().splitlines()
                self.assertEqual(sum(call.startswith("cat") for call in calls), 1)
                deletions = [call for call in calls if "--delete-generations" in call]
                self.assertEqual(len(deletions), int(expected is not None), calls)
                if expected: self.assertTrue(deletions[0].endswith(f"+{expected}"), deletions)

    def test_utm_retention_rejects_malformed_metadata(self):
        log, info_file, _, _, enabled = self.utm_retention_fixture()
        for metadata in ("not json", "[]", json.dumps({"profiles": []}), *(
            json.dumps({"profiles": {"vm-image": profile}}) for profile in (
                enabled | {"schemaVersion": 2}, enabled | {"keepGenerations": "9"},
                enabled | {"keepGenerations": 0}, enabled | {"autoCleanGenerations": "true"},
                enabled | {"enable": "true"}, {}, [], None, False))):
            with self.subTest(metadata=metadata):
                info_file.write_text(metadata)
                log.write_text("")
                result = self.run_hey("utm", "update", "review", "--wait", "5")
                self.assertNotEqual(result.returncode, 0, result.stdout)
                calls = log.read_text()
                self.assertNotIn("--delete-generations", calls)
                self.assertNotIn("switch-to-configuration", calls)

    def test_utm_retention_uses_newly_activated_policy(self):
        log, info_file, current_file, next_info, enabled = self.utm_retention_fixture()
        # Changed closures must use the newly activated retention policy too.
        for new_policy, expected in ((enabled | {"autoCleanGenerations": False}, None),
                                     (enabled | {"keepGenerations": 7}, 7)):
            with self.subTest(activated=new_policy):
                current_file.write_text("/nix/store/fixture-old-system")
                info_file.write_text(json.dumps({"profiles": {"vm-image": enabled}}))
                next_info.write_text(json.dumps({"profiles": {"vm-image": new_policy}}))
                log.write_text("")
                result = self.run_hey("utm", "update", "review", "--wait", "5")
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                calls = log.read_text().splitlines()
                self.assertIn("switch", calls)
                self.assertEqual(sum(call.startswith("cat") for call in calls), 2)
                deletions = [call for call in calls if "--delete-generations" in call]
                self.assertEqual(len(deletions), int(expected is not None), calls)
                if expected: self.assertTrue(deletions[0].endswith(f"+{expected}"), deletions)

    def test_utm_explicit_retention_does_not_require_metadata(self):
        log, info_file, _, _, _ = self.utm_retention_fixture()
        # Manual cleanup is deliberate: an explicit count works without metadata.
        info_file.write_text("unavailable metadata")
        log.write_text("")
        result = self.run_hey("utm", "cleanup-generations", "review", "--keep-generations", "5")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("--delete-generations +5", log.read_text())
        self.assertFalse(any(call.startswith("cat") for call in log.read_text().splitlines()))

    def test_utm_verification_refuses_effective_password_auth_before_cleanup(self):
        log, info_file, _, _, enabled = self.utm_retention_fixture()
        info_file.write_text(json.dumps({"profiles": {"vm-image": enabled}}))
        script = (self.root / "mock-bin/ssh").read_text().split("\n", 1)[1]
        self.mock_command("ssh", script.replace('elif "sshd -T -G" in remote: print("no")',
                                                 'elif "sshd -T -G" in remote: print("yes")'))
        result = self.run_hey("utm", "update", "review", "--wait", "5")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Effective SSH password authentication", result.stderr)
        self.assertNotIn("--delete-generations", log.read_text())

    def test_utm_ssh_preserves_existing_trust(self):
        # Stub only external processes. Exercise the real UTM command and SSH
        # argument construction, with no network, UTM installation or real HOME.
        mock_bin = self.root / "mock-bin"
        mock_bin.mkdir()
        self.env["DOTFILES_BIN"] = str(mock_bin)
        self.env["HOME"] = str(self.root / "user")
        known_hosts = Path(self.env["HOME"]) / ".ssh/known_hosts"
        known_hosts.parent.mkdir(parents=True)
        known_hosts.write_text("existing pinned host key\n")
        known_hosts.with_suffix(".old").write_text("previous backup\n")
        log = self.root / "ssh-args.json"
        scripts = {
            "hey": 'import sys\nassert sys.argv[1:3] == ["utm", "ip"]\nprint("192.0.2.1")\n',
            "ssh": f'import json, sys\nfrom pathlib import Path\nPath({str(log)!r}).write_text(json.dumps(sys.argv[1:]))\nsys.exit(255)\n',
            "ssh-keygen": 'raise RuntimeError("must not modify known_hosts")\n',
            "utmctl": 'import sys\nprint("UUID STATUS NAME\\nfixture-id started fixture" if sys.argv[1] == "list" else "started")\n',
            "ps": 'pass\n',
        }
        for name, script in scripts.items():
            executable = mock_bin / name
            executable.write_text(f"#!{sys.executable}\n" + script)
            executable.chmod(0o755)
        for command, expected in [
            (["ssh", "fixture", "hostname"], "ask"),
            (["update", "fixture", "--wait", "1"], "yes"),
            (["doctor", "fixture", "--wait", "1"], "yes"),
        ]:
            with self.subTest(command=command):
                if log.exists():
                    log.unlink()
                result = self.run_hey("utm", *command)
                self.assertNotEqual(result.returncode, 0)
                self.assertTrue(log.exists(), result.stdout + result.stderr)
                args = json.loads(log.read_text())
                self.assertIn(f"StrictHostKeyChecking={expected}", args)
                self.assertNotIn("StrictHostKeyChecking=accept-new", args)
                self.assertEqual(known_hosts.read_text(), "existing pinned host key\n")
                self.assertEqual(known_hosts.with_suffix(".old").read_text(), "previous backup\n")

    def test_clean_preserves_tracked_build_sources(self):
        subprocess.run(["git", "init", "--quiet", str(self.consumer)], check=True)
        disposable = self.consumer / "target"
        disposable.mkdir()
        (disposable / "output.txt").write_text("build output\n")
        target = self.consumer / "build"
        target.mkdir()
        source = target / "source.txt"
        source.write_text("tracked source\n")
        subprocess.run(["git", "-C", str(self.consumer), "add", "build/source.txt"], check=True)
        result = self.run_hey("project", "clean", "--yes")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Refusing to remove tracked", result.stderr)
        self.assertEqual(source.read_text(), "tracked source\n")
        # Validate every target before removing even the untracked outputs.
        self.assertTrue((disposable / "output.txt").exists())

    def test_clean_refuses_unverifiable_git_state(self):
        target = self.consumer / "build"
        target.mkdir()
        result = self.run_hey("project", "clean", "--yes")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Could not verify tracked files", result.stderr)
        self.assertTrue(target.exists())

    def test_clean_preserves_nested_repositories_and_gitfiles(self):
        subprocess.run(["git", "init", "--quiet", str(self.consumer)], check=True)
        (self.consumer / ".gitignore").write_text("build/\n")
        build = self.consumer / "build"
        build.mkdir()
        for name, separate in (("nested", False), ("worktree", True)):
            nested = build / name
            args = ["git", "init", "--quiet"]
            if separate:
                args += ["--separate-git-dir", str(self.root / "git-state")]
            subprocess.run([*args, str(nested)], check=True)
            (nested / "source.txt").write_text("tracked nested source\n")
            subprocess.run(["git", "-C", str(nested), "add", "source.txt"], check=True)
        disposable = build / "output.txt"
        disposable.write_text("disposable output\n")
        result = self.run_hey("project", "clean", "--yes")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(disposable.exists())
        for name in ("nested", "worktree"):
            self.assertEqual((build / name / "source.txt").read_text(), "tracked nested source\n")
            self.assertTrue((build / name / ".git").exists())

    def test_help_without_activation_environment(self):
        self.env = {key: value for key, value in self.env.items() if not key.startswith("XDG_")}
        result = self.run_hey("-h")
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
