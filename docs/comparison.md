# Where Nixi fits

Research date: 2026-09-08. This is an architectural comparison of documented
interfaces, not a performance benchmark, popularity ranking, or security audit.
Descriptions of other projects come from their primary documentation; Nixi
assessments come from this source tree. Recommendations are our interpretation.

## Different tools, different layers

| Project | Documented focus | Relationship to Nixi |
| --- | --- | --- |
| [Plain NixOS modules and flakes](https://nixos.org/manual/nixos/stable/#sec-writing-modules) | Reusable system modules and declarative configuration | Already permit public mechanisms and private consumers. Nixi adds conventions, modules and a workflow CLI; it does not invent this separation. |
| [flake-parts](https://flake.parts/) | Modular composition of standard flake outputs, with a small core and optional ecosystem modules | Nixi's composition helpers overlap with this layer. flake-parts is a strong choice when reusable output composition is all you need; Nixi carries more integrated workflow and policy. |
| [Snowfall Lib](https://snowfall.org/guides/lib/quickstart/) | Generate flake outputs using an opinionated directory structure | Closest overlap in discovery/layout conveniences. Nixi accepts explicit host descriptors and ordinary policy inputs; choosing it is a workflow/API preference, not proof Snowfall cannot separate private policy. |
| [nixos-unified](https://nixos-unified.org/) | Unified NixOS, nix-darwin and Home Manager configuration, activation, remote activation, optional autowiring | A direct comparator for cross-platform host management. It already offers consistent activation and reusable composition. Nixi's additional emphasis is `hey` diagnostics, VM/image workflows and project-native command adapters. |
| [hlissner/dotfiles](https://github.com/hlissner/dotfiles) | A personal configuration and experimentation repository; explicitly not advertised as a community framework | Nixi inherits ideas and code from this work. Nixi aims to make the reusable portion a supported standalone consumer dependency, without shipping the maintainer's host inventory. This is productization, not an independent invention. |
| [devenv](https://devenv.sh/) | Declarative development environments, languages, services, processes, tasks and tests | Prefer it for an integrated project-environment model. Nixi instead delegates project commands to existing project definitions and additionally manages hosts/VMs. Complementary scopes; integration must be tested rather than assumed. |
| [Devbox](https://www.jetify.com/docs/devbox) | Reproducible development shells described with `devbox.json` | Prefer it when a team wants package-driven project environments without authoring a host framework. Nixi exposes Nix directly and solves a broader, more demanding host/workflow problem. |
| [Flox](https://flox.dev/docs/) | Manifest-based package/environment management, sharing, services and cross-platform environments | Prefer it for environment distribution and onboarding with less Nix knowledge. Nixi's host-module and private-policy contract addresses another layer; shell isolation is not a host privacy guarantee for either tool. |

## Defensible positioning

> Nixi provides reusable Nix mechanisms and a consistent host, VM and project
> workflow without requiring users to publish or inherit the maintainer's host
> configuration.

The combination matters more than any individual feature:

- `lib.mkHostFlake` consumes an explicit inventory from the consumer.
- Framework source paths and consumer workspace paths remain distinct.
- Ordinary inputs supply shared policy; no special private-site backend is required.
- Consumer dependency pins can override framework defaults.
- Outputs remain standard Nix outputs; `hey` is an adapter, not a replacement evaluator.
- Synthetic fixture checks exercise composition and secret-provider boundaries.

These are source-backed design claims, not guarantees that arbitrary modules,
inputs, logs or build artifacts cannot reveal private information.

## Tradeoffs and gaps

Nixi is not policy-free. Its core integrates Home Manager, while the tool
collection and opinionated profiles/themes are opt-in. Nix version, cache trust,
trusted users and unfree-package policy belong to the consumer. Those boundaries
are documented in [Getting started](getting-started.md).

It also maintains custom Nix composition helpers and a Janet CLI. That creates
maintenance and onboarding costs compared with using standard modules plus an
established composition library. Home Manager is currently integrated into host
configuration, not exposed as an equivalent standalone home-only product.

Do not claim "the only clean separation", "more secure by design", "zero policy",
"faster", or "better than popular Nix tools" without evidence. No comparative
benchmarks or third-party adoption study were performed. A public/private split
is achievable with the other composition tools too.

## Recommendation

Choose Nixi when you want its coherent cross-platform host/VM tooling, diagnostic
workflow and explicit private-consumer contract, and accept its defaults and
custom tooling maintenance burden. Choose another layer when that better matches your
need: flake-parts for output composition, nixos-unified for unified activation,
or devenv/Devbox/Flox for project-environment delivery. These choices need not
be mutually exclusive, but coexistence is not the same as verified integration.
