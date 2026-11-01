# Runtime and release tools

This directory contains tools used outside the test suite:

- `install_user_file.py`: privileged-source, unprivileged-destination file installation.
- `ssh_certificate.py`: runtime certificate signing, validation and installation.
- `openvpn_credentials.py`: runtime preparation of OpenVPN credential files.
- `runtime_input.py`: bounded regular-file reads and the private SAML input bridge.
- `agent_config.py`: structural TOML/YAML diagnostics; emits statuses, not config values.
- `ssh_diagnostics.py`: bounded public certificate/CA validation and conservative static client-config checks; never executes SSH config.
- `tmux-status/`: the program used by the tmux status bar.
- `process-supervisor/`: native lifecycle supervision of Hey's captured commands.
- `release.py`: maintainer tooling for auditing and exporting reviewed releases.

The Python regression tests and isolated CLI runner live in
[`../test_tools/`](../test_tools/). Nix check definitions remain in `../checks/`,
and Janet tests remain in `../test/`. Test helpers are not runtime packages.
