# V3.4 Health Check

`HEALTH_CHECK.cmd` is the user-facing runtime diagnostic for Codex Multi-Model Manager.

## Default behavior

The default run is diagnostic-first. It may read:

- PowerShell / Codex / Git availability;
- `~/.codex/config.toml` and Manager profile files;
- `codex login status`;
- whether known provider environment-variable names have values at Process/User scope;
- current Git repository branch / HEAD / working-tree status;
- OpenRouter `/api/v1/models` when OpenRouter is configured and a key is available.

It never prints API-key values and never runs paid model inference.

A JSON report is written under:

```text
~/.codex/multimodel-manager/reports/
```

No health report is written inside a project repository.

## Checks

The current checker reports PASS / WARN / BLOCK for:

- PowerShell 7;
- Codex CLI availability/version;
- Git availability;
- Codex config presence;
- `forced_login_method = "api"` conflicts with ChatGPT + third-party coexistence;
- legacy Manager `[profiles.mm_*]` tables in base config;
- provider-specific global `model_catalog_json` leakage;
- old ChatGPT profile hard-coding `model = "gpt-5.6"`;
- ChatGPT login state;
- configured provider + expected environment-variable presence;
- read-only OpenRouter catalog reachability and Ox Alpha catalog presence;
- Git handoff readiness;
- custom/stealth metadata fallback warnings.

Optional providers that are not configured are reported as SKIP, not failures.

## Safe repair

Run:

```powershell
pwsh -NoProfile -File .\installer\scripts\health-check.ps1 -Repair
```

or launch `installer/HEALTH_CHECK.cmd` and accept the repair prompt after blockers are found.

Repair can:

1. invoke the existing backup-preserving Profile V2 migration;
2. isolate a legacy provider-specific global model catalog into `legacy-codex-catalog.config.toml` without deleting the old `models.json`;
3. normalize the ChatGPT profile so it does not force the rejected legacy `gpt-5.6` ID;
4. optionally comment out an active `forced_login_method = "api"` line after explicit user confirmation.

`-Yes` exists for deterministic tests/automation and should not be used casually when a user has not approved the configuration change.

## Safety boundaries

Health Check must not:

- display or write secret values;
- run paid inference;
- modify project files;
- run `git reset`, `git clean`, or `git stash`;
- delete the preserved custom model catalog;
- invent context-window, tool, or reasoning metadata for an unknown third-party/stealth model.

Unknown model metadata remains a WARN until reliable metadata is available from the provider or Codex catalog.
