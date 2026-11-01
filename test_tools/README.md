# Test-only tools

Python regression tests and their isolated behavioral-test runner live here.
They are part of the public source so contributors and CI can verify Nixi, but
are not installed as user commands or used by activation scripts.

From the Nixi root:

```sh
python3 test_tools/test_release.py
python3 test_tools/test_install_user_file.py
python3 test_tools/test_openvpn_credentials.py
python3 test_tools/test_cli_runner.py
python3 test_tools/test_shell_startup.py
python3 test_tools/test_check_plan.py
python3 test_tools/run_cli_tests.py TEST_NAME
```

`check_plan.py` validates `check-policy.json` against all framework check
definitions and Nix's available platform check names. It prints native build
names only; it never executes Nix or builds anything. Public CI consumes this
plan after evaluation, so new checks cannot be silently omitted. Evaluation-only
classification is for assertion-only checks; VM tests remain a separate gate.

Use the isolated runner for behavioral CLI tests; it limits resources and stops
after the first failure. Supply the packaged Janet dependencies as described in
the checks, plus `HEY_PROCESS_SUPERVISOR` pointing at the packaged native helper
(or put `nixi-process-supervisor` on PATH). Both the runner and its unit tests
require it; there is no Python process-group cleanup fallback.
Parser/login tests also need `HEY_RUNTIME_PYTHON` from `nix develop` (Python
3.11+ with PyYAML and Cryptography). `nix build .#checks.SYSTEM.runtime-inputs` supplies that
interpreter and the pinned OpenSSH parser for input/policy tests.

`run_contract_tests.py` runs `unit`, `cli` and `utm-cli` in fresh synthetic homes
and local stores, with bounded output/deadlines and mocked process/SSH/VM probes.
It is wired into `checks.SYSTEM.cli-contracts` on both native CI platforms.
Keep these command-contract suites and the Python behavioral suite distinct;
both are required. Do not assume `flake check --no-build` executes either.
Do not launch broad integration tests beside valuable interactive
work while the previously reported resource-exhaustion issue remains unresolved.

`test_ssh_certificate.py` needs the packaged certificate helper and Cryptography;
run it through `nix build .#checks.SYSTEM.ssh-certificate-tool`.
Other tests likewise have Nix entrypoints listed in [`../checks/README.md`](../checks/README.md).
`test_process_supervisor.py` is a bounded, serial native lifecycle suite. Run it
through `nix build .#checks.SYSTEM.process-supervisor` to supply the matching
helper and Janet interpreter. It uses synthetic, self-expiring process trees,
never live services. The public CI runs it natively on Linux and macOS.
Imports resolve runtime code from the sibling `tools/` directory, independent of
the caller's working directory. No copies of runtime implementations live here.
The shell startup tests use temporary homes and mocked selector commands. Their
generated activation case is supplied by the `zsh-plugins` Nix check; direct
Python invocation explicitly skips that case when the fixture is absent.
