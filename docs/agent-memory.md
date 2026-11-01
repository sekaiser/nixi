# Optional engineering memory

`modules.agents.memory.enable = true` installs a pinned TencentDB-Agent-Memory
MemoryCore and starts a per-user service on `127.0.0.1:8420` (launchd on Darwin,
systemd user service on Linux). When Codex is enabled, activation registers one
`tencent-memory` stdio MCP entry. Native Codex authentication and model transport
are unchanged. This is not MemoryProxy or the upstream full-stack installer.

```nix
modules.agents = {
  codex.enable = true;
  memory.enable = true;
};
```

Other agents, projects, private paths and project knowledge are not built into
the module. `configureCodex = false` disables registration. `port` chooses an
unprivileged loopback port. `stateDirectory` chooses a canonical runtime path
outside the Nix store; default: `${home.stateDir}/nixi-agent-memory`.

## Privacy and ownership

State is user-owned, mode 0700. A random bearer token is generated at runtime in
`gateway-token`, mode 0600; it never enters a derivation or Codex configuration.
SQLite, JSONL mirrors and logs remain in that private directory. The service
does not inherit model keys, cloud credentials, Node hooks, HTTP proxies or
telemetry endpoints. There is no external extraction/embedding model configured.
Capture, extraction, embeddings, skills and external telemetry exporters are
disabled. Local upstream diagnostic logging remains enabled. No existing
conversation history is imported. Search currently uses keyword/BM25 retrieval,
not hybrid/vector retrieval. There is no separate Tencent CodeGraph deployment.

Codex activation preserves other configuration, comments, model providers and
authentication settings. It refuses symlinked or non-private config files and
an existing unowned `tencent-memory` entry. It owns only the explicitly marked
block. Config files must be user-owned mode 0600; existing Codex directories
may be mode 0755 but must not be writable by others. Runtime state directories
must be mode 0700. Registration conflicts fail activation rather than overwrite
user configuration. No snapshot of Codex configuration is stored in Nix.

Disabling this module stops the managed service on activation but deliberately
does not erase memories or mutable Codex configuration. Remove the marked MCP
block explicitly if no longer wanted. Restart Codex after activation.

Local-only is not protection against malicious processes running as the same
user, a compromised upstream package, or prompt injection. Retrieved content
is sent to the coding model when you use it; local storage does not make model
processing local. Do not save credentials, private keys, or material prohibited
by your organisation's data policy. Logs/backups of the runtime directory need
the same protection as its database. Port health information is unauthenticated
upstream; data operations require the generated bearer token.

## On-demand workflow

Three tools are exposed, with Codex approval prompts:

- `search_memory`: keyword search in an explicit project namespace, at most five
  records. No automatic prompt injection or whole-project history loading.
- `record_chat_note`: explicitly selected chat context, always marked proposed.
- `remember_engineering_claim`: a claim with project, full Git revision, at least
  one evidence reference, status and dependency list. Status must be `proposed`,
  `accepted`, `rejected` or `superseded`; accepted requires explicit user review.

Records are structured L0 Chat Memory messages. They are not model-extracted L1
facts. Assistant-only writes do not schedule the upstream user-round extraction
pipeline. Every search result is labelled untrusted historical context. The
adapter validates provenance shape, not the truth or existence of cited evidence.
User approval is a workflow gate, not cryptographic proof of review. Git and
the consumer's canonical evidence workspace remain authoritative; a passed unit
test is not a passed promotion gate.

Writes append rather than silently replace history. To supersede a decision,
append a superseded record referencing its memory ID in `dependencies`, and
append the replacement claim with its evidence. Keyword search is not an
exhaustive supersession check: verify current canonical evidence before acting.
Project namespaces are logical isolation, not access control between mutually
untrusted users; the adapter has access to this user's complete memory service.

## Qualification before adoption

Run 20–30 representative completed tasks in fresh sessions, holding model and
source revision fixed. Compare correct decision recovery, source accuracy,
rework, tokens and mistaken promotion of rejected/superseded claims. The shipped
tests verify synthetic operation, auth, isolation and provenance contracts;
they do not establish that memory improves engineering outcomes.

The native Nix check evaluates Linux/Darwin service definitions and runs offline
adapter tests. For the real Core round trip, build `packages.<system>.tencent-memory-core`
and run `test_tools/test_agent_memory.py` with `NIXI_MEMORY_CORE` set to its binary
path outside the Nix build sandbox. The test uses synthetic state and an ephemeral
loopback port, then terminates the service. Darwin's build sandbox forbids such
listeners; it is not relaxed for this check.

The source revision and npm dependency lock are pinned. OpenTelemetry versions
are adjusted within this package for GHSA-8988-4f7v-96qf and GHSA-45rx-2jwx-cxfr;
telemetry remains disabled. The dependency audit reported zero known npm
vulnerabilities on 2026-10-13; this is not a guarantee of absence of defects.
Package updates require
reviewing both, regenerating the dependency hash and rerunning tests. No global
dependency override is introduced. The package includes upstream production
dependencies only, without the OpenClaw/llama optional peers, development tools,
or lifecycle scripts. This remains experimental, not a complete security audit.
