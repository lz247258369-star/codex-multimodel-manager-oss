# Codex Desktop Router Compatibility Matrix (LR-13)

Status: evidence tracked, Desktop not installed on the verification machine

Last verified: 2026-09-03

Scope: **Codex Desktop only.** This matrix records what the currently
verifiable Codex Desktop installation supports for a Router-owned
`mm_local_router` provider. It never patches the Desktop, never runs a live
provider request, never performs paid inference, and never probes `/models`.

## Test environment

- `codex --version` -> `codex-cli 0.149.1` (CLI only; **not** evidence for Desktop)
- Desktop detection on 2026-09-03:
  - no Codex Desktop executable/installer detected under `%LOCALAPPDATA%\Programs`
    or App Paths;
  - only the unrelated `OpenAI.ChatGPT-Desktop` WindowsApps package exists;
  - running `codex` processes are the CLI/app-server daemons, not Codex Desktop.

## Matrix

| # | Capability | Status | Evidence |
|---:|---|---|---|
| A | Codex Desktop installed | NOT INSTALLED | No Desktop package/executable detected on this machine. |
| B | Desktop version/build | NOT INSTALLED | No Desktop binary to query. |
| C | Desktop reads `~/.codex/config.toml` | NOT VERIFIED | Requires installed Desktop; not inferred from CLI. |
| D | Desktop custom `model_provider` behavior | NOT VERIFIED | Requires installed Desktop. |
| E | Desktop `wire_api = "responses"` | NOT VERIFIED | Requires installed Desktop. |
| F | Desktop loopback `base_url` | NOT VERIFIED | Requires installed Desktop. |
| G | Desktop `env_key` behavior | NOT VERIFIED | Requires installed Desktop. |
| H | Desktop `requires_openai_auth = false` | NOT VERIFIED | Requires installed Desktop. |
| I | Desktop selected model | NOT VERIFIED | Requires installed Desktop. |
| J | Desktop `model_reasoning_effort` | NOT VERIFIED | Requires installed Desktop. |
| K | Full restart requirement | NOT VERIFIED | Required by the adapter contract; Desktop proof pending. |
| L | New conversation requirement | NOT VERIFIED | Required by the adapter contract; Desktop proof pending. |
| M | Existing-thread hot-switch | NOT VERIFIED | Not supported by design; no Desktop evidence. |
| N | Official model picker shows custom models | NOT VERIFIED | Not supported by design claim; picker injection is forbidden. |

## Loopback Desktop evidence

```text
DESKTOP LOOPBACK COMPAT =
NOT VERIFIED / SAFE AUTOMATION UNAVAILABLE
```

Safe automation of the real Codex Desktop is unavailable on this machine
(Desktop not installed; no firewall-isolated fixture). LR-13 does not run
Desktop automation that could touch a live provider.

## Design boundaries

- Desktop Router reuses the single Router provider identity `mm_local_router`
  shared with LR-12 (never `mm_desktop_router` or per-provider identities).
- Responses only; loopback only; no Chat Completions; no Anthropic wire.
- Full restart + new conversation required; no existing-thread hot switch.
- Official Desktop binaries, bundles, model picker, and account auth are never
  modified or injected.
- No upstream provider key is added by the Router adapter; only
  `CODEX_LOCAL_ROUTER_TOKEN` belongs at the Desktop boundary (and only when
  compatibility evidence proves an .env copy is required).
