---
name: codex-multimodel-manager
description: Configure, diagnose, discover, test, approve, and safely switch Codex among ChatGPT official models and third-party Responses-compatible models. Includes one-click health checks, explicit safe repair, automatic new-model discovery, Git handoff protection, approved-model registration, and stealth-model reveal/migration tracking.
---

# Codex Multi-Model Manager V3.4.0

## Runtime requirement

Use **PowerShell 7 (`pwsh`)** for this Skill and installer. The scripts are UTF-8 and contain non-ASCII UI text; legacy Windows PowerShell 5.1 can mis-decode UTF-8 without BOM on some Windows locales.

Install PowerShell 7 on Windows with:
`winget install --id Microsoft.PowerShell -e --source winget`

## Core workflow

Preferred path:
`ChatGPT login -> Codex official model catalog -> account-supported official model`

Fallbacks:
configured MiMo / Qwen / DeepSeek via Responses / Grok / Groq / OpenRouter / dynamically approved models.

Before troubleshooting a model launch, prefer the **Health Check**. It catches common local causes before asking the user to edit TOML manually.

## V3.4 Health Check

Run:
`pwsh -NoProfile -File <skill>/scripts/health-check.ps1`

The default check is diagnostic-first and may inspect:

- PowerShell / Codex / Git availability;
- `~/.codex/config.toml` and Manager profile files;
- `codex login status`;
- active `forced_login_method = "api"` conflicts;
- legacy Manager `[profiles.mm_*]` data in base config;
- provider-specific global `model_catalog_json` leakage;
- an old ChatGPT profile hard-coding `model = "gpt-5.6"`;
- configured provider definitions and whether their expected environment variable exists at Process/User scope;
- current Git branch / HEAD / worktree state;
- OpenRouter `/api/v1/models` when OpenRouter is configured and a key is available.

Health Check must never print API-key values or run paid inference.

### Safe repair

Only after explicit user approval, run:
`pwsh -NoProfile -File <skill>/scripts/health-check.ps1 -Repair`

Repair may:

1. invoke the existing backup-preserving Profile V2 migration;
2. isolate a legacy provider-specific global model catalog into `legacy-codex-catalog.config.toml` while preserving the old `models.json`;
3. normalize the ChatGPT profile so it does not force the rejected legacy `gpt-5.6` ID;
4. comment out an active `forced_login_method = "api"` only after a separate confirmation.

`-Yes` is for deterministic tests/automation where approval was already obtained. Do not use it to bypass user consent.

Health reports belong only under:
`~/.codex/multimodel-manager/reports/`

Unknown third-party/stealth model metadata is a WARN. Do not invent context-window, tool, reasoning, or capability metadata merely to silence Codex fallback warnings.

## Automatic model discovery

When a provider releases a new model:

1. **Discover automatically** through the provider's model-list endpoint when available.
2. Compare against the local discovery baseline.
3. Put genuinely new IDs in the **candidate registry**.
4. Do **not** automatically trust or activate the model.
5. Run a minimal `/responses` smoke test only after user approval because inference may cost money.
6. Optionally run a tool-calling probe.
7. Register only after the user explicitly approves.
8. Back up Codex config before registration.
9. Keep project repositories untouched.

## Stealth Model Registry

Anonymous/stealth models have a different lifecycle from normal stable model IDs. Track them by a persistent alias and keep the temporary model ID as historical state.

Current seeded alias:

```text
Ox Alpha -> stealth/ox-alpha
```

Registry runtime files:

```text
~/.codex/multimodel-manager/stealth-models.json
~/.codex/multimodel-manager/stealth-model-history.jsonl
```

Rules:

- Automatic discovery may check whether a tracked stealth ID still exists.
- If the ID disappears with no confirmed replacement, mark it `MISSING_NEEDS_REVIEW`.
- Metadata/name matches may be displayed as **suspected replacements only**.
- Never infer or record an official identity from speculation alone.
- A replacement ID may be recorded only after the user explicitly invokes migration and types `MIGRATE`.
- Before recording migration, verify the replacement ID exists in the live OpenRouter catalog.
- Preserve the old anonymous ID; do not delete its history.
- Once a confirmed replacement is live, alias-based launch resolves to the replacement ID.
- If a recorded replacement is unavailable but the old stealth ID is still live, the launcher may temporarily use the old live ID and clearly report that state.
- If neither ID is live, stop instead of guessing.
- Never make a stealth model the default model or automatic ChatGPT fallback.
- Never change project code merely because a stealth model was renamed/revealed.

Commands:

Sync/read lifecycle state:
`pwsh -ExecutionPolicy Bypass -File <skill>/scripts/sync-stealth-registry.ps1`

Open the registry center:
`pwsh -ExecutionPolicy Bypass -File <skill>/scripts/stealth-model-center.ps1`

Record a confirmed reveal/migration:
`pwsh -ExecutionPolicy Bypass -File <skill>/scripts/record-stealth-reveal.ps1 -Alias "Ox Alpha" -NewModelId "vendor/model-id"`

Generic alias launch:
`pwsh -ExecutionPolicy Bypass -File <skill>/scripts/launch-stealth-model.ps1 -Alias "Ox Alpha" -ConfirmationCode "OX"`

## Ox Alpha experimental policy

Ox Alpha remains an anonymous/stealth model until an official reveal is recorded. The compatibility alias is `Ox Alpha`; its original tracked ID is `stealth/ox-alpha`.

Rules:

- Require the existing `mm_openrouter` Responses provider and `OPENROUTER_API_KEY` for launch.
- Resolve the alias through the Stealth Model Registry before launch.
- Verify the resolved ID is present in OpenRouter's current `/api/v1/models` catalog.
- Require the user to type `OX` before launching it.
- Do not automatically replace ChatGPT official models, MiMo, Qwen, DeepSeek, or another configured fallback with Ox Alpha.
- Do not make claims about the hidden model provider's identity unless officially disclosed.
- Preserve the normal Git handoff gate before switching.

Launch through:
`pwsh -ExecutionPolicy Bypass -File <skill>/scripts/launch-ox-alpha.ps1`

## Automatic discovery safety

Discovery may be automatic. Activation is not silent.

Scheduled discovery:
- may call read-only `/models` endpoints;
- may update user-level new-model and stealth lifecycle state;
- must not run paid inference tests;
- must not rewrite Codex config;
- must not modify project files;
- must not change the selected/default model;
- may only write reports/state under `~/.codex/multimodel-manager/`.

## Commands

### Health check
`pwsh -NoProfile -File <skill>/scripts/health-check.ps1`

### Discover new models
`pwsh -ExecutionPolicy Bypass -File <skill>/scripts/discover-models.ps1`

### Model update center
`pwsh -ExecutionPolicy Bypass -File <skill>/scripts/model-update-center.ps1`

### Compatibility probe
Basic:
`pwsh -ExecutionPolicy Bypass -File <skill>/scripts/probe-model.ps1 -ProviderId "<provider>" -ModelId "<model>"`

Tool probe:
add `-RunToolProbe`.

Never run a probe without telling the user that it may consume a small amount of API usage.

### Approve/register
Only after basic Responses PASS and explicit approval:
`pwsh -ExecutionPolicy Bypass -File <skill>/scripts/approve-model.ps1 -ProviderId "<provider>" -ModelId "<model>"`

### Switch
`pwsh -ExecutionPolicy Bypass -File <skill>/scripts/switch-model.ps1`

### Git handoff
Before switching:
`collect-handoff.ps1`

After switching:
`resume-handoff.ps1`

If it reports `HANDOFF DRIFT`, do not continue writing until the difference is explained.

## Storage

All manager state is user-level:

- `~/.codex/multimodel-manager/state.json`
- `~/.codex/multimodel-manager/discovery-baseline.json`
- `~/.codex/multimodel-manager/discovered-models.json`
- `~/.codex/multimodel-manager/candidates.json`
- `~/.codex/multimodel-manager/approved-models.json`
- `~/.codex/multimodel-manager/stealth-models.json`
- `~/.codex/multimodel-manager/stealth-model-history.jsonl`
- `~/.codex/multimodel-manager/reports/`
- `~/.codex/handoffs/`
- `~/.codex/backups/`

Never store manager state inside a user's project repository.

## Config ownership

The manager owns its marked configuration blocks and the dedicated Manager profile files it records in its ownership manifest. A preserved `legacy-codex-catalog.config.toml` is intentionally **not** disposable Manager state because it represents pre-existing user configuration.

Never overwrite unrelated user/provider/project configuration.

## API keys

Never write API key values to TOML, Markdown, AGENTS.md, project `.env`, Git, or reports. Use Windows user environment variables.

## Future model policy

A higher version number does not automatically mean "better for Codex".
For a normal new model, distinguish:

- `NEW`: newly discovered
- `RESPONSES_PASS`: basic Responses API works
- `VERIFIED`: basic + tool-calling probe passed
- `APPROVED`: user explicitly registered it
- `PROBE_FAILED`: compatibility test failed

For a stealth alias, distinguish:

- `TRACKING`
- `ACTIVE_STEALTH`
- `MISSING_NEEDS_REVIEW`
- `REVEAL_RECORDED`
- `REVEALED_ACTIVE`
- `REVEAL_RECORDED_OLD_ID_ACTIVE`
- `REPLACEMENT_MISSING`

Do not replace the current ChatGPT official model or a configured fallback merely because a newer model appears. Recommend replacement only after compatibility and task-quality evaluation.

## Project safety

Changing models changes the model/provider used by Codex, not the Git repository. Never use model switching, health repair, or stealth-model migration as a reason to reset/stash/clean/overwrite project work.

If `AGENTS.md` exists, its project development gate remains authoritative.
