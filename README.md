# Codex Multi-Model Manager

Windows-oriented Codex multi-model manager for a **ChatGPT official-model first, fallback when needed** workflow.

## Open source

- Licensed under the [Apache License 2.0](LICENSE).
- This is an independent community project. It is **not affiliated with, endorsed by or sponsored by OpenAI**;
  "Codex" and "ChatGPT" are referenced only to describe compatibility.
- Provided **as is, without warranty** (see the licence). You are responsible for your Provider accounts,
  API keys and any usage charges.
- Report security problems privately as described in [SECURITY.md](SECURITY.md); contribution rules are in
  [CONTRIBUTING.md](CONTRIBUTING.md).
- History starts at a sanitized import; see [docs/OSS_GENESIS.md](docs/OSS_GENESIS.md).

## Runtime requirements

- Windows
- Codex CLI
- Git
- **PowerShell 7 (`pwsh`)**

Install PowerShell 7 with:

```powershell
winget install --id Microsoft.PowerShell -e --source winget
```

PowerShell 7 is required because the manager scripts are UTF-8 and include non-ASCII UI text. Legacy Windows PowerShell 5.1 can mis-decode those scripts on some locales. All `.cmd` entrypoints in v3.3.1+ check for `pwsh.exe` before running.

## Repository layout

```text
codex-multimodel-manager/
├─ skill/
│  └─ codex-multimodel-manager/
│     ├─ SKILL.md
│     ├─ scripts/
│     └─ references/
├─ installer/
│  ├─ CODEX_DESKTOP_CONTROLLER.cmd
│  ├─ ONE_CLICK_SETUP.cmd
│  ├─ CODEX_MODEL_SWITCHER.cmd
│  ├─ HEALTH_CHECK.cmd
│  ├─ MODEL_UPDATE_CENTER.cmd
│  ├─ CHECK_NEW_MODELS.cmd
│  ├─ STEALTH_MODEL_REGISTRY.cmd
│  ├─ INSTALL_SKILL_ONLY.cmd
│  ├─ LAUNCH_OX_ALPHA_EXPERIMENTAL.cmd
│  ├─ ENABLE_WEEKLY_MODEL_CHECK.cmd
│  ├─ DISABLE_WEEKLY_MODEL_CHECK.cmd
│  ├─ setup.ps1
│  ├─ install-skill.ps1
│  └─ scripts/
├─ docs/
│  ├─ DESKTOP_CONTROLLER.md
│  ├─ HEALTH_CHECK.md
│  ├─ OX_ALPHA.md
│  └─ STEALTH_MODEL_REGISTRY.md
├─ tests/
│  ├─ validate-repo.ps1
│  ├─ validate-desktop-controller.ps1
│  ├─ validate-health-check.ps1
│  ├─ validate-ox-alpha.ps1
│  └─ validate-stealth-registry.ps1
├─ .github/workflows/
│  └─ ci.yml
├─ AGENTS.md
├─ CHANGELOG.md
├─ manifest.json
└─ README.md
```

The **Codex Skill is intentionally easy to find under `skill/`**. Windows setup/runtime files live under `installer/`, documentation under `docs/`, and the CI validation gate under `tests/` + `.github/workflows/`.

## Quick start

On Windows:

1. Install PowerShell 7 if `pwsh --version` is unavailable.
2. Open `installer/`.
3. Run `ONE_CLICK_SETUP.cmd` to configure providers and install the Skill.
4. Run `HEALTH_CHECK.cmd` to verify Codex/login/profile/provider/Git readiness and optionally repair known safe configuration conflicts.
5. Run **`CODEX_DESKTOP_CONTROLLER.cmd`** for the graphical provider-aware model launcher.
6. Keep `CODEX_MODEL_SWITCHER.cmd` as the command-line fallback.
7. Run `MODEL_UPDATE_CENTER.cmd` to discover/test/approve newly released models.
8. Run `STEALTH_MODEL_REGISTRY.cmd` to track anonymous-model disappearance, official reveal, and model-ID migration.

If you only want the Skill, run `installer/INSTALL_SKILL_ONLY.cmd`.

The Skill payload copied into `$CODEX_HOME/skills/` is:

```text
skill/codex-multimodel-manager/
```

## V3.5 Desktop Controller

V3.5 adds a lightweight Windows WPF control center on top of the existing Manager runtime.

Launch it with:

```text
installer/CODEX_DESKTOP_CONTROLLER.cmd
```

The Controller provides buttons for:

- GPT-5.6 / ChatGPT official account model;
- Qwen3 Coder Plus via Alibaba Model Studio;
- DeepSeek V4 Pro via Alibaba Model Studio;
- Ox Alpha via OpenRouter Stealth Registry;
- GLM 5.3 via OpenRouter;
- MiMo V2.5 Pro via Xiaomi MiMo.

It also shows the selected project's Git branch, HEAD, and CLEAN/DIRTY state, and exposes Health Check, handoff verification, provider setup, and the legacy command-line switcher.

Most importantly, **every model button launches a new Codex CLI session**. The Controller does not try to reuse an old DeepSeek/Qwen/OpenRouter Desktop thread after changing providers, which avoids the model/provider mismatch that can occur when the visible Desktop model changes but the old thread's provider remains bound.

The GUI does not inject third-party models into the official Codex Desktop dropdown and does not patch the official app. It is an external provider-aware launcher using the existing Manager profiles, environment variables, and handoff logic.

See `docs/DESKTOP_CONTROLLER.md`.

## V3.4 one-click Health Check

V3.4 adds a diagnostics-first health check that reports `PASS`, `WARN`, `BLOCK`, or `SKIP` without exposing API-key values.

It checks:

- PowerShell 7, Codex CLI, and Git availability;
- ChatGPT login state;
- `forced_login_method = "api"` conflicts;
- old Manager Profile V2 tables still living in base `config.toml`;
- legacy provider-specific `model_catalog_json` leaking globally into ChatGPT `/model`;
- old ChatGPT profile hard-coding `model = "gpt-5.6"`;
- configured provider definitions and whether their expected user/process environment variable is set;
- optional read-only OpenRouter `/models` reachability and Ox Alpha catalog presence;
- current Git branch/HEAD/worktree readiness for handoff;
- unknown third-party/stealth metadata fallback warnings.

Run:

```text
installer/HEALTH_CHECK.cmd
```

or choose option `13` in `CODEX_MODEL_SWITCHER.cmd`.

If blockers are found, the entrypoint can offer a **safe repair**. Repair remains explicit, backs up Codex configuration, preserves the old custom `models.json`, never runs paid inference, and never modifies project files. V3.4 intentionally warns about unknown custom-model metadata rather than inventing context-window or capability values.

Health reports are stored only under:

```text
~/.codex/multimodel-manager/reports/
```

See `docs/HEALTH_CHECK.md`.

## Automatic model discovery

The manager can discover new model IDs from configured provider `/models` endpoints. New IDs enter a candidate registry first; they are not silently trusted or activated. Paid Responses/tool-calling probes require confirmation, and a model is registered only after explicit approval.

## Stealth Model Registry

V3.3 adds lifecycle tracking for anonymous/stealth aliases.

The first seeded alias is:

```text
Ox Alpha -> stealth/ox-alpha
```

The registry tracks:

- alias and original anonymous ID;
- current status and last-seen time;
- whether the anonymous ID disappeared;
- metadata-based suspected replacements (informational only);
- a user-confirmed replacement ID and official name;
- reveal/migration history.

Automatic discovery also performs a read-only stealth lifecycle sync. It may notice that a stealth ID disappeared, but it **cannot** decide that another model is the official replacement.

A reveal/migration is recorded only after:

1. the new OpenRouter model ID is verified live;
2. the user types `MIGRATE`.

The old anonymous ID remains in history. Alias-based launch resolves to the confirmed replacement when it is live, otherwise to the still-live old ID, and stops if neither exists.

See `docs/STEALTH_MODEL_REGISTRY.md`.

## Ox Alpha experimental support

Ox Alpha remains an explicit experimental choice and never becomes the automatic ChatGPT fallback.

Launch through option `11` in `CODEX_MODEL_SWITCHER.cmd` or:

```text
installer/LAUNCH_OX_ALPHA_EXPERIMENTAL.cmd
```

The Ox launcher delegates to the generic Stealth Model Registry. If Ox Alpha is later officially revealed and you record the replacement ID, the same alias can follow that confirmed mapping without hard-coding a second launcher.

The launch still requires:

- `OPENROUTER_API_KEY`;
- the `mm_openrouter` Responses provider;
- a live resolved model ID in OpenRouter's catalog;
- explicit `OX` confirmation;
- Git handoff protection when launched from a repository.

See `docs/OX_ALPHA.md`.

## Development Gate CI

GitHub Actions runs the **Development Gate** workflow on pull requests to `main`, pushes to `main`, and manual dispatches.

The `development-gate` job performs static, non-destructive validation, including:

- repository / Skill / installer structure;
- PowerShell syntax parsing;
- Skill frontmatter checks;
- installer-to-Skill path checks;
- required runtime script checks;
- forbidden destructive Git command checks;
- legacy `wire_api = "chat"` checks in executable scripts;
- common committed-secret pattern checks;
- Codex auth/runtime-state tracking checks;
- Windows entrypoint target checks;
- V3.4 Health Check repair/isolation regression coverage;
- dedicated Ox Alpha launcher/switcher safety checks;
- Stealth Model Registry parity and migration-safety checks;
- V3.5 Desktop Controller entrypoint/model-route/Git-safety checks.

Local equivalent:

```powershell
pwsh ./tests/validate-repo.ps1
pwsh ./tests/validate-health-check.ps1
pwsh ./tests/validate-ox-alpha.ps1
pwsh ./tests/validate-stealth-registry.ps1
pwsh ./tests/validate-desktop-controller.ps1
```

CI never calls paid model inference and never mutates the real user Codex configuration.

## Core goals

- keep project code and Git history independent from model/provider switching;
- keep API keys out of repositories and Codex TOML files;
- preserve existing Codex configuration;
- make provider setup and switching easy;
- protect handoffs between models with Git state snapshots;
- discover future models without silently activating them;
- track anonymous-model reveal/rename without guessing identity;
- catch common local runtime/configuration conflicts before launch;
- automatically catch repository/Skill safety regressions before they reach `main`.

## Versioning

- `v2.0.0`: one-click provider setup, safe switching, Git handoff.
- `v3.0.0`: automatic model discovery, candidate registry, compatibility probes, explicit approval, dynamic model registration, optional weekly discovery.
- `v3.1.0`: GitHub Actions Development Gate CI and reusable repository validation script.
- `v3.2.0`: guarded Ox Alpha (`stealth/ox-alpha`) integration through OpenRouter plus dedicated safety validation.
- `v3.3.0`: Stealth Model Registry with alias tracking, disappearance detection, explicit reveal migration, and alias-based launch resolution.
- `v3.3.7`: legacy custom-catalog isolation and ChatGPT account-supported official model fallback.
- `v3.4.0`: one-click runtime health diagnostics, explicit safe repair, provider/login/profile/Git checks, read-only OpenRouter catalog health, and user-level JSON health reports.
- `v3.5.0`: Windows WPF Desktop Controller with provider-aware new-session launching and project/Git status UI.

## Security

This repository must never contain real API key values, Codex `auth.json`, user project data, or runtime state under `~/.codex/`.
Report vulnerabilities privately; see [SECURITY.md](SECURITY.md).
