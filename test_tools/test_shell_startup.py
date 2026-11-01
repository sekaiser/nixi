"""Isolated shell/selector regressions: no real sessions, homes or credentials."""
import os
import json
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ShellStartup(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory(prefix="nixi-shell-")
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name).resolve()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.zdot = self.root / "config/zsh"
        self.zdot.mkdir(parents=True)
        self.env = {"HOME": str(self.root), "PATH": str(self.bin) + ":" + os.environ["PATH"],
                    "ZDOTDIR": str(self.zdot), "TERM": "xterm-256color",
                    "XDG_CACHE_HOME": str(self.root / "cache")}
        for name in ("plugins.zsh", "completion.zsh", "keybinds.zsh", "aliases.zsh"):
            (self.zdot / name).write_text("# fixture\n")
        (self.zdot / "extra.zshrc").write_text("autopair-init() { :; }\n")
        # Security fixtures need the real completion engine, not thousands of
        # unrelated system completion definitions. Keep the deadline meaningful
        # on native Darwin's sandbox too. Full plugin startup is checked below
        # by the Nix-generated terminal fixture with its actual fpath.
        self.completion_core = self.root / "completion-core"
        self.completion_core.mkdir()
        for function in ("compinit", "compaudit", "compdump", "compinstall"):
            result = self.zsh('for directory in $fpath; do '
                              'if [[ -f "$directory/$1" ]]; then '
                              'print -r -- "$directory/$1"; break; fi; done', function)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(result.stdout.strip(), "Missing Zsh completion engine")
            shutil.copyfile(result.stdout.strip(), self.completion_core / function)

    def executable(self, name, body):
        target = self.bin / name
        target.write_text(f"#!{sys.executable}\n" + body)
        target.chmod(0o755)
        return target

    def zsh(self, script, *args):
        return subprocess.run([shutil.which("zsh"), "-f", "-c", script, "fixture", *map(str, args)],
                              env=self.env, capture_output=True, text=True, timeout=10)

    def completion(self, *fpaths):
        return self.zsh('fpath=("${@:3}" "$1"); source "$2"; '
                        'print -r -- "COMPLETION=${_comps[nixi-fixture]:-none}"; '
                        'print -r -- "CACHE=$ZCOMPCACHE"', self.completion_core, ROOT / "assets/zsh/completion.zsh", *fpaths)

    def test_completion_audits_use_local_case_sensitive_globbing(self):
        cache_directory = self.root / "cache/zsh"
        cache_directory.mkdir(parents=True, mode=0o700)
        for mode in (0o700, 0o777):
            with self.subTest(cache_mode=oct(mode)):
                cache_directory.chmod(mode)
                result = self.zsh('compinit() { print -r -- "AUDIT_CASE_GLOB=$options[caseglob]"; }; '
                                  'source "$1"; print -r -- "SHELL_CASE_GLOB=$options[caseglob]"',
                                  ROOT / "assets/zsh/completion.zsh")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("AUDIT_CASE_GLOB=on", result.stdout)
                self.assertIn("SHELL_CASE_GLOB=off", result.stdout)
                self.assertEqual("unsafe completion cache" in result.stderr, mode == 0o777)

    def test_insecure_completion_is_excluded_fresh_and_cached(self):
        untrusted = self.root / "untrusted"
        untrusted.mkdir(mode=0o700)
        (untrusted / "_nixi_fixture").write_text("#compdef nixi-fixture\nprint UNSAFE_COMPLETION\n")
        # Start with a trusted entry in the dump, then revoke directory trust.
        result = self.completion(untrusted)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("COMPLETION=_nixi_fixture", result.stdout)
        untrusted.chmod(0o777)
        for cached in (True, False):
            if not cached:
                shutil.rmtree(self.root / "cache/zsh")
            result = self.completion(untrusted)
            self.assertEqual(result.returncode, 0, result.stderr)
            # A cached autoload name may remain, but the unsafe search path may
            # never remain available for resolution.
            probe = self.zsh('fpath=("$1" "$3"); source "$2"; '
                             '(( ${fpath[(Ie)$1]} == 0 ))', untrusted, ROOT / "assets/zsh/completion.zsh", self.completion_core)
            self.assertEqual(probe.returncode, 0, probe.stderr)
            if not cached:
                self.assertIn("COMPLETION=none", result.stdout)

    def test_unsafe_cache_source_compiled_file_and_parent_are_not_loaded(self):
        for attack in ("source", "compiled", "symlink", "directory", "ancestor"):
            with self.subTest(attack=attack):
                self.env["XDG_CACHE_HOME"] = str(self.root / attack)
                result = self.completion()
                self.assertEqual(result.returncode, 0, result.stderr)
                cache = Path(next(line[6:] for line in result.stdout.splitlines() if line.startswith("CACHE=")))
                if attack == "source":
                    cache.write_text("print UNSAFE_CACHE\n")
                    cache.chmod(0o666)
                elif attack == "compiled":
                    compiled = Path(str(cache) + ".zwc")
                    compiled.chmod(0o666)
                elif attack == "symlink":
                    cache.unlink()
                    cache.symlink_to(self.root / "missing-cache")
                elif attack == "directory":
                    cache.parent.chmod(0o777)
                else:
                    cache.parent.parent.chmod(0o777)
                (self.zdot / ".zcompdump").write_text("print UNSAFE_CACHE\n")
                result = self.completion()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("unsafe completion cache", result.stderr)
                self.assertNotIn("UNSAFE_CACHE", result.stdout)
                self.assertIn("CACHE=\n", result.stdout)

    def test_aliases_preserve_path_installed_hey_without_activation(self):
        self.executable("hey", 'print("PACKAGED_HEY")\n')
        result = self.zsh('compdef() { :; }; source "$1"; hey', ROOT / "assets/zsh/aliases.zsh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "PACKAGED_HEY")

    def test_init_helper_ignores_legacy_executable_caches(self):
        generator = self.executable("generator", 'print("print FRESH_INIT")\n')
        version = self.zsh('print -r -- "$ZSH_VERSION"').stdout.strip()
        cached = self.root / "cache/zsh" / ("generator-" + version)
        cached.parent.mkdir(parents=True)
        victim = self.root / "legacy-output"
        victim.write_text('print UNSAFE_CACHE\n')
        for attack in ("writable", "symlink", "compiled", "ancestor"):
            with self.subTest(attack=attack):
                cached.unlink(missing_ok=True)
                cached.write_text('print UNSAFE_CACHE\n')
                if attack == "writable":
                    cached.chmod(0o666)
                elif attack == "symlink":
                    cached.unlink()
                    cached.symlink_to(victim)
                elif attack == "compiled":
                    self.assertEqual(self.zsh('zcompile "$1"', cached).returncode, 0)
                else:
                    cached.parent.chmod(0o777)
                result = subprocess.run([shutil.which("zsh"), "-f", "-i", "-c",
                    'fpath=("$1" $fpath); autoload -Uz hey.cache; hey.cache "$2"',
                    'fixture', str(ROOT / "runtime/zsh"), str(generator)],
                    env=self.env, capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("FRESH_INIT", result.stdout)
                self.assertNotIn("UNSAFE_CACHE", result.stdout)
                self.assertEqual(victim.read_text(), 'print UNSAFE_CACHE\n')

    def test_init_helper_respects_arguments_upgrades_and_generator_failure(self):
        generator = self.executable("generator", 'import sys\nprint("print INIT_" + sys.argv[1])\n')
        def invoke(argument):
            return subprocess.run([shutil.which("zsh"), "-f", "-i", "-c",
                'fpath=("$1" $fpath); autoload -Uz hey.cache; hey.cache "$2" "$3"',
                'fixture', str(ROOT / "runtime/zsh"), str(generator), argument],
                env=self.env, capture_output=True, text=True, timeout=10)
        for argument in ("ONE", "TWO"):
            self.assertIn("INIT_" + argument, invoke(argument).stdout)
        self.executable("generator", 'print("print UPGRADED_INIT")\n')
        self.assertIn("UPGRADED_INIT", invoke("ONE").stdout)
        self.executable("generator", 'import sys\nprint("print MUST_NOT_EXECUTE")\nsys.exit(17)\n')
        result = invoke("ONE")
        self.assertEqual(result.returncode, 17, result.stderr)
        self.assertNotIn("MUST_NOT_EXECUTE", result.stdout)
        self.assertFalse((self.root / "cache").exists())

    def test_auto_attach_uses_explicit_selector_without_hey(self):
        self.executable("uname", 'print("Darwin")\n')
        selector = self.executable("selector with space", 'import sys\nprint("SELECTOR_CALLED")\nsys.exit(1)\n')
        self.env.update(HEY_TMUX_AUTO_ATTACH="1", HEY_TMUX_SELECTOR=str(selector))
        for terminal, expected in (("ordinary", True), ("zed", False)):
            self.env["TERM_PROGRAM"] = terminal
            result = self.zsh('source "$1"; print SHELL_READY', ROOT / "assets/zsh/.zshrc")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual("SELECTOR_CALLED" in result.stdout, expected)
            self.assertIn("SHELL_READY", result.stdout)
        self.env["TERM_PROGRAM"] = "ordinary"
        self.env["HEY_TMUX_SELECTOR"] = str(self.root / "missing-selector")
        result = self.zsh('source "$1"; print SHELL_READY', ROOT / "assets/zsh/.zshrc")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("selector unavailable", result.stderr)
        self.assertIn("SHELL_READY", result.stdout)

    @unittest.skipUnless(os.getenv("NIXI_ZSH_CLEANUP"), "generated activation supplied by Nix check")
    def test_generated_user_cleanup_is_narrow_and_honors_dry_run(self):
        script = Path(os.environ["NIXI_ZSH_CLEANUP"]).read_text()
        # The Nix fixture uses this canonical path. Replace complete shell
        # arguments, retaining quoting even for the hostile destination name.
        directory = self.root / "config with ' quotes/zsh"
        directory.mkdir(parents=True)
        for name in (".zshrc", ".zshenv", ".zcompdump", "plugins.zsh", "completion.zsh",
                     "keybinds.zsh", "aliases.zsh", "extra.zshrc", "extra.zshenv"):
            script = script.replace(shlex.quote(f"/fixture/alice/.config/zsh/{name}.zwc"),
                                    shlex.quote(str(directory / (name + ".zwc"))))
        managed = directory / ".zshrc.zwc"
        unrelated = directory / "custom.zwc"
        victim = self.root / "outside"
        victim.write_text("keep")
        managed.symlink_to(victim)
        unrelated.write_text("keep")
        for dry_run in (True, False):
            wrapper = "run() { :; }; " if dry_run else 'run() { "$@"; }; '
            result = self.zsh(wrapper + script)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(managed.is_symlink(), dry_run)
            self.assertEqual(unrelated.read_text(), "keep")
            self.assertEqual(victim.read_text(), "keep")

    @unittest.skipUnless(os.getenv("NIXI_ZSH_MINIMAL"), "generated minimal shell supplied by Nix check")
    def test_generated_minimal_shell_loads_user_config_without_plugins(self):
        fixture = json.loads(Path(os.environ["NIXI_ZSH_MINIMAL"]).read_text())
        extra = self.zdot / "extra.zshrc"
        extra.write_text(fixture["extra"])
        startup = fixture["startup"].replace(
            shlex.quote("/fixture/alice/.config/zsh/extra.zshrc"), shlex.quote(str(extra)))
        result = self.zsh(fixture["environment"] + "\n" + startup + '\n'
                          '[[ $NIXI_MINIMAL_INIT == ready && $NIXI_MINIMAL_ENV == ready ]] || exit 1; '
                          '(( ! $+functions[autopair-init] && ! $+functions[hey_tmux_status_precmd] ))')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertEqual(result.stderr, "")

    def test_tmuxsel_preserves_interactive_choices_with_mocked_commands(self):
        self.executable("pgrep", 'print("123")\n')
        self.executable("tmux", '''import json, os, sys
from pathlib import Path
args = sys.argv[1:]
if args[0] == "display-message": sys.exit(1)
if args[0] == "list-sessions":
    print("one\\ntwo words")
else:
    Path(os.environ["TMUXSEL_LOG"]).write_text(json.dumps(args))
''')
        import json
        log = self.root / "tmux-args"
        self.env["TMUXSEL_LOG"] = str(log)
        for choice, expected in (("\n", ["new-session"]), ("named session\n", ["new-session", "-s", "named session"]),
                                 ("2\n", ["attach", "-t", "two words"]), ("nil\n", None)):
            log.unlink(missing_ok=True)
            result = subprocess.run([shutil.which("bash"), str(ROOT / "bin/tmuxsel")], input=choice,
                                    env=self.env, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0 if expected else 1, result.stderr)
            self.assertEqual(json.loads(log.read_text()) if log.exists() else None, expected)


if __name__ == "__main__":
    unittest.main()
