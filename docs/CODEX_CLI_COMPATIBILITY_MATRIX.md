# Codex CLI Compatibility Matrix (LR-12)

Status: evidence tracked, live-run fixture documented separately

Last verified: 2026-09-03 (loopback fixture executed against real Codex CLI 0.149.1)

Scope: **Codex CLI only.** This matrix records what the currently installed Codex
CLI verifiably supports for a Router-owned custom provider/profile. It never
uses `auth.json`, never calls a live model provider, never runs paid inference,
and never probes `/models`.

## Tested environment

- `codex --version` -> `codex-cli 0.149.1`
- `codex --help` confirms the CLI exposes:
  - `-p, --profile <CONFIG_PROFILE_V2>` (layers `$CODEX_HOME/<name>.config.toml`)
  - `-m, --model <MODEL>`
  - `-c, --config <key=value>`
  - `exec`, `resume`, `fork`, `doctor`
- Production Direct Mode in this repository already launches Codex against
  custom `[model_providers.mm_*]` blocks that use `wire_api = "responses"`,
  `env_key`, and `requires_openai_auth = false`.

## Loopback fixture evidence

On 2026-09-03 the repository compatibility runner
(`tests/fixtures/local-router/codex-cli/run-codex-compat.ps1`) ran on
`127.0.0.1` against the real `codex-cli 0.149.1` binary with an isolated
temporary `CODEX_HOME` and `CODEX_LOCAL_ROUTER_TOKEN`. The runner starts the
fake Router fixture
(`tests/fixtures/local-router/codex-cli/fake-router.ps1`), enables the
Router-owned profile, launches Codex with `-m`, and verifies the recorded
request. Codex launched with:

```text
model: deepseek-v4-pro
provider: mm_local_router
approval: never
sandbox: read-only
reasoning effort: high
```

The runner recorded repeated `POST /v1/responses` requests where:

- path was `/v1/responses` on the loopback Router port;
- `Authorization: Bearer <CODEX_LOCAL_ROUTER_TOKEN>` matched the expected local
  token (value never printed or committed);
- request body model was the `-m` selected model (`qwen3-coder-plus` in the
  current fixture run).

Runner result (real Codex 0.149.1):

```text
CODEX LOOPBACK COMPAT = RUN
LOOPBACK REQUESTS = 6
POST /v1/responses = YES
AUTHORIZATION LOCAL TOKEN = YES
MODEL = qwen3-coder-plus
LIVE PROVIDER = NO
CODEX LOOPBACK COMPAT = PASS
```

When a CI or local machine has no Codex binary, the runner exits with:

```text
CODEX LOOPBACK COMPAT = NOT RUN / CODEX CLI UNAVAILABLE
```

That status is never reported as PASS.

The fixture is intentionally minimal: it proves Codex sends a legal Responses
request to the Router-owned loopback profile. The fixture reply is not a full
Responses-compatible Router implementation, so the Codex session performs its
stream reconnection attempts after the text deltas are echoed. Full end-to-end
stream completion is owned by the Local Router (LR-3/LR-8) and is not claimed
from this fixture.

## Matrix

| # | Capability | Status | Evidence |
|---:|---|---|---|
| A | Custom `model_provider` definition | SUPPORTED | Fixture banner shows `provider: mm_local_router`; Direct Mode custom providers use the same mechanism. |
| B | `wire_api = "responses"` | SUPPORTED | Router profile uses Responses; fixture proves Codex accepted the profile and sent a Responses request. |
| C | `base_url = http://127.0.0.1:<port>/v1` | SUPPORTED | Runner recorded `POST /v1/responses` on the loopback Router port. |
| D | `env_key = CODEX_LOCAL_ROUTER_TOKEN` | SUPPORTED | Runner recorded matching `Authorization: Bearer` from that env reference; no literal token in config. |
| E | `requires_openai_auth = false` | SUPPORTED | Runner reached the custom provider without a ChatGPT login or `auth.json`. |
| F | Custom model ID | SUPPORTED | Runner request body carried the `-m` selected model (`qwen3-coder-plus`). |
| G | Profile startup (`-p <profile>`) | SUPPORTED | Runner launched through `codex -p mm_local_router`; Profile V2 config was parsed. |
| H | `-m / --model` override on startup | SUPPORTED | Runner shows the `-m` value reaching the loopback request body. |
| I | Native `/model` inside an already running session | NOT VERIFIED | Requires an interactive session; not yet proven with the Router profile. |
| J | Native `/model` lists the custom Router provider | NOT VERIFIED | No interactive evidence yet; must not be assumed. |
| K | Native `/model` lists Router-owned model IDs | NOT VERIFIED | No interactive evidence yet; must not be assumed. |
| L | Native `/model` switch keeps `mm_local_router` | NOT VERIFIED | No interactive evidence yet; must not be assumed. |

## What this means for LR-12

The supported and verified path is:

```text
select Router model before launch
  -> Router-owned profile (mm_local_router.config.toml)
  -> codex --profile mm_local_router -m <selected-model>
  -> POST http://127.0.0.1:<port>/v1/responses
```

In-session native `/model` switching of third-party Router models is **not
claimed**. Until an interactive fixture proves otherwise, LR-12 treats native
in-session custom-model switching as unsupported by the currently verified
Codex CLI and requires a fresh launch for a model change.

## Boundaries

- Codex sees exactly one secret reference: `CODEX_LOCAL_ROUTER_TOKEN`.
- Upstream provider keys stay behind the Local Router.
- When Codex is launched in Router Mode, upstream provider secret values are
  removed from the child process environment and restored afterwards; only
  `CODEX_LOCAL_ROUTER_TOKEN` is present for the child.
- Codex-side retries are disabled (`request_max_retries = 0`,
  `stream_max_retries = 0`); retry ownership belongs to the Local Router (LR-11).
- Model and reasoning-effort selection are validated against the canonical
  `installer/model-catalog.json` and the enabled Router model routes; arbitrary
  model strings, ambiguous routes, unapproved routes, and unsupported efforts
  fail closed.

## Provider selection scope in LR-12

Codex CLI model selection is available for the Router providers that have a
canonical capability source in `installer/model-catalog.json`:

- `mm_modelstudio`
- `mm_openrouter`
- `mm_mimo`

`mm_openai_api` is **NOT Codex-selectable in LR-12**:

```text
MM_OPENAI_API_CATALOG_CAPABILITY_GAP
```

The canonical catalog contains no `mm_openai_api` provider section and no
versioned reasoning/effort capability metadata for that provider. ChatGPT
account identity is `DIRECT_ONLY` and is never remapped to `mm_openai_api`.
Until a separate prerequisite PR adds a versioned capability source for
`mm_openai_api` (catalog/schema extension or registry projection), any
`mm_openai_api` Router model route fails closed with the gap code above.
- No `auth.json` access; ChatGPT remains Direct-only.
- No OpenCodex runtime, no second proxy, no Chat Completions wire.
- No Desktop or V4 integration in LR-12.
