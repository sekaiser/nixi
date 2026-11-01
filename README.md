# Nixi

Experimental: no stable API or long-term support guarantee yet. See
[security policy](SECURITY.md) for reporting and support boundaries.

Nixi is a thin, composable workflow layer for Nix-native developer systems.
It is designed to configure hosts, VMs, project environments, developer tools,
and verification workflows without introducing a second framework when the
underlying tools are already sufficient.

The goal is frictionless daily development with CI/CD parity. The same
declarative inputs that configure a laptop, VM, or project should also be
usable for checks, builds, deployments, and automation.

## Purpose

Nixi focuses on the parts of the software delivery lifecycle that usually
become fragmented across dotfiles, shell scripts, VM provisioning steps,
project-specific setup notes, and CI-only commands:

- host and VM configuration
- reusable module and profile composition
- project shells, checks, and local service workflows
- developer tooling, shell, editor, terminal, and agent setup
- diagnostics and repair commands through `hey`
- CI/CD-friendly verification of systems and projects

Nix remains the source of truth for systems, packages, shells, checks, and
builds. `hey` is the ergonomic command surface around that source of truth.

Start with [Getting started](docs/getting-started.md) and the synthetic consumer
in [examples/minimal](examples/minimal). Keep real host inventories in your own
private repository. Nixi ships reusable mechanisms and opinionated defaults,
not the maintainer's machines. See [comparison](docs/comparison.md) for tradeoffs
and [publication boundaries](docs/publishing.md) before distributing a snapshot.

## Design Principles

- **Nix-native first.** Prefer flakes, modules, packages, dev shells, and checks
  before introducing a new project framework.
- **Thin workflow glue.** `hey` should make common operations pleasant, but it
  should not become the only way to perform them.
- **CI/CD parity.** Local commands should map to commands CI can run directly,
  such as `nix flake check`, `nix develop -c ...`, or `hey project ci`.
- **Minimal required abstractions.** Tools such as `devenv`, `devbox`, or
  `flox` can be supported as implementation backends, but should not be
  required concepts.
- **Project flexibility.** Projects may use plain flakes, `direnv`, `just`,
  `process-compose`, language-native tools, or a higher-level backend when it
  is justified.
- **Explicit boundaries.** Reusable framework code should not depend on private
  host, project, or secret details. Hosts and sites provide policy; modules
  provide mechanism.
- **Agent-aware development.** Modern agentic development tools are part of the
  developer system, but their configuration should respect existing provider
  directories and remain automation-friendly.

## Scope

Nixi owns the reusable framework:

- module loading and composition helpers
- host and workspace layout conventions
- reusable Darwin, Linux, and shared modules
- packages, templates, checks, and overlays
- the `hey` command implementation
- documentation of supported architecture patterns

Sites and hosts own concrete policy:

- host inventory
- private Git, cloud, Kubernetes, and company configuration
- SOPS files and secret names
- project-specific or fleet-specific defaults
- environment-specific endpoint and service choices

Projects own their development workflow contract:

- `flake.nix` for shells, packages, and checks
- `.envrc` for local activation when useful
- `process-compose.yaml` for local long-running services when needed
- `justfile`, Makefile, or language-native commands for project tasks
- optional backends such as `devenv` only when they provide real value

## Project Workflow Direction

Nixi should make project workflows easier without replacing the project model.
The preferred baseline is:

```text
project/
  flake.nix
  .envrc
  process-compose.yaml  # optional
  justfile              # optional
```

The intended command shape is:

```text
hey project shell
hey project check
hey project test
hey project up
hey project down
hey project status
hey project ci
```

Those commands should be thin adapters over project-native definitions. For
example, `hey project up` can use `process-compose` when a project declares
services, while `hey project check` can delegate to `nix flake check`, `just
check`, or a language-native check command.

Higher-level tools such as `devenv` are compatible with this direction, but
they should remain optional implementation details rather than first-class
requirements. The framework should optimize for technical necessity, not for
wrapping every possible workflow in another abstraction.

## Further Reading

- [Architecture](docs/architecture.md)
- [Flake Composition API](docs/flake-api.md)
- [Hey CLI](docs/hey.md)
- [Modules](modules/README.md)
- [Secrets](docs/secrets.md)
- [SSH](docs/ssh.md)
- [Git](docs/git.md)
