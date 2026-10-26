# Local Router V4 UI (LR-14)

## Page structure

The Local Router page is the sixth V4 navigation page (index 5). Existing pages
0-4 (Dashboard, Models, Providers, Stealth, Tools) and their indices are
unchanged. `NavRouter` is appended after `NavTools`.

The page presents, in order:

- Router feature / lifecycle / readiness badges and the configured-vs-runtime
  feature distinction;
- CLI route state (DIRECT/ROUTER) and Desktop route state (DIRECT/ROUTER);
- `Overall`: DIRECT / ROUTER / MIXED (presentation only);
- CLI Router (LR-12) and Desktop Router (LR-13) action cards;
- Feature mutation controls (`启用 Router 功能` / `停用 Router 功能`), passive
  health, cross-model and circuit-breaker status;
- bounded Usage / estimated Cost, configured-vs-effective Policy with
  generation-aware mutation, bounded safe recent-request metadata;
- Safe Restore Direct affordance and known limitations.

## Control plane is the only data source

LR-14 V4 consumes the LR-14P authenticated Control Plane contracts documented in
[LOCAL_ROUTER_LR14P_CONTROL_PLANE.md](LOCAL_ROUTER_LR14P_CONTROL_PLANE.md) and
versioned in `local-router/schemas/control-plane-*.v1.schema.json`:

| Purpose | Request |
| --- | --- |
| Router feature / lifecycle / health / mutation availability | `GET /v1/router/control-plane/status` |
| Bounded usage and estimated cost | `GET /v1/router/control-plane/usage?limit=N` |
| Bounded safe recent requests | `GET /v1/router/control-plane/requests?limit=N` |
| Configured vs effective policy | `GET /v1/router/control-plane/policy` |
| Generation-aware policy mutation | `PUT /v1/router/control-plane/policy` |
| Generation-aware feature mutation | `PUT /v1/router/control-plane/feature` |

The legacy `GET /v1/router/status` endpoint is **not** an LR-14 UI data source.
The UI never derives Usage/Cost/Recent/Policy/Health from it, never scans raw
durable logs, never reads a directory, and never fabricates a second status
contract.

Every request uses the existing bearer token from `CODEX_LOCAL_ROUTER_TOKEN`
(Process, then User scope) and the existing `router:control-plane` scope. No
second token store is introduced; the token is never displayed, never logged,
and never written to visual state.

## Loopback and fail-closed targeting

Only `127.0.0.1` with a valid port (1-65535) may be contacted. A configured
remote host or an invalid port produces no network request at all and a fixed
UI warning. Feature state is request admission state, not process existence, so
a running-but-disabled Host stays observable and can be re-enabled from V4.

## Refresh model

- One persistent background runspace performs all HTTP work; no network call
  ever runs on the WPF UI thread.
- A 4-second dispatcher timer triggers a refresh while the Local Router page is
  selected; a pre-warmed engine avoids runspace creation inside the tick.
- One in-flight refresh at a time, a refresh generation guard, and window
  closing disposal protect the UI from stale or overlapping results.
- A refresh cycle reads control-plane status first. An unreachable Host
  short-circuits and never waits on usage/requests/policy.
- Only safe allowlisted DTO fields cross back to the UI thread; raw
  `HttpResponseMessage`, headers, exception text, stack traces, URLs, and paths
  never do.

## Direct / Router / MIXED

- `DIRECT`: CLI and Desktop are both Direct.
- `ROUTER`: CLI and Desktop are both Router.
- `MIXED`: one client is Router and the other is Direct.

Direct Mode remains the default. Opening or refreshing V4 performs no write and
no mutation request; Router stays disabled unless explicitly enabled.

## Feature mutation (enable / disable)

`启用 Router 功能` / `停用 Router 功能` call `PUT
/v1/router/control-plane/feature` with `expected_generation` from the latest
control-plane snapshot. They change the request admission flag only.

- Feature Enable is **not** process Start. `LIFECYCLE_CONTROL_GAP = YES`; the UI
  never offers Start / Stop / Restart, and a failed or unavailable live
  mutation is reported instead of rewriting `router.config.json` directly.
- Buttons are enabled only while `feature_mutation_available` is true and the
  Host is reachable; otherwise they are disabled.
- Generation conflict (`409`) shows a fixed message
  (`配置已被其他操作更新，请刷新后重试。`), never retries the mutation
  automatically, and only re-reads the authoritative snapshot.

## Health

Production passive health comes from the control-plane `health_summary`
projection: availability plus healthy / degraded / unhealthy / unknown route
counts and the snapshot timestamp. No endpoint, provider secret, or raw health
exception is displayed.

## Usage and Cost

- Usage: bounded record count, capacity, known/unknown usage, and input/output
  token totals from `GET /v1/router/control-plane/usage`.
- Unknown is never zero: a `null` token total renders as `未知（≠ 0）`.
- Cost: per-currency estimated totals from the same projection, listed
  separately and never summed across currencies.
- Cost is an informational estimate, never billing truth. Unknown or missing
  prices render as `未知 / 不可用（≠ $0.00）`; an explicit zero is only shown
  when the contract reports a complete known cost.

## Policy

The policy card shows configured vs effective Retry, Timeout, and Failover for
the selected policy, taken from `GET /v1/router/control-plane/policy`. Editor
fields are initialized from that real snapshot; PowerShell defines no policy
defaults of its own.

Saving submits exactly one typed body kind with the latest
`expected_generation`. On success the new server generation is adopted, any
in-flight stale refresh is invalidated, and a fresh read is triggered. A
`409 generation conflict` never silently overwrites and never auto-retries.

- Cross-model fallback: HARD OFF, with no enable control.
- Circuit breaker: `effective = disabled`, `configured = null`,
  `mutation_available = false`, reported as not configurable
  (`CIRCUIT_BREAKER_POLICY_CONFIGURATION_GAP = YES`); no breaker mutation is
  implemented.

## CLI Router operations (LR-12)

Enable/Disable/Launch buttons dispatch to the existing
`router-codex-cli.ps1` (`-Action Enable/Disable/Launch`). The UI does not
rewrite `config.toml`, and the CLI Router control is not the Router feature
switch. Model options come from `Get-RouterCliAvailableModels` (canonical
catalog + enabled Router routes); reasoning effort follows the selected model's
declared capability.

## Desktop Router operations (LR-13)

Desktop Router activate/restore dispatch to `desktop-router-route.ps1`.
Activation requires confirmation and states: full Desktop exit, restart, new
conversation, no thread hot-switch, no Desktop binary modification, restore
available. Existing V4 Direct Desktop controls are untouched and remain
separate.

## Safe Restore Direct

Safe Restore re-reads fresh local state (never a cached display snapshot) and
only restores the Router-related CLI/Desktop routes. It never deletes secrets,
never deletes provider config, never disables the Router feature, and never
kills a Router process.

## Safety summary

- open/refresh: zero writes, zero mutation requests, zero provider requests;
- no prompt, response, reasoning, tool, secret, endpoint, or path content;
- no `auth.json` access, no token display, no paid inference;
- no direct `router.config.json` mutation for Control Plane actions.

## Known limitations

- Codex CLI native in-session `/model` custom Router switching: NOT VERIFIED.
- Desktop existing-thread hot switch: UNSUPPORTED BY DESIGN.
- mm_openai_api remains fail-closed (`MM_OPENAI_API_CATALOG_CAPABILITY_GAP`);
  ChatGPT is never mapped to mm_openai_api.
- Runtime Start/Stop/Restart and process lifecycle ownership remain unavailable
  (`LIFECYCLE_CONTROL_GAP = YES`); LR-14 provides feature admission mutation
  only.
- Circuit breaker configuration remains unavailable
  (`CIRCUIT_BREAKER_POLICY_CONFIGURATION_GAP = YES`).
- Desktop real runtime evidence: NOT VERIFIED / DESKTOP NOT INSTALLED.
