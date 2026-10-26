# Local Router Runtime

Standalone skeleton for the optional Local Router runtime described in
`docs/LOCAL_ROUTER_RUNTIME_ARCHITECTURE.md`. Implemented slices:

LR-1 (core skeleton):
- typed lifecycle state machines with compare-and-set terminalization;
- typed `RequestId` / `TraceId` / `AttemptId` backed by RFC 9562 UUIDv7;
- immutable `RequestContext`;
- normalized, serialization-stable `RouterError`;
- cancellation propagation with idempotent cancel;
- fakeable clock and fakeable ID generator;
- a default-disabled `Router.Host` executable that exits safely without binding,
  serving, reading config, or touching user state.

LR-2 (configuration, state, secrets, ownership):
- schema-v1 `RouterConfig` defaults + field-level user merge, validated
  fail-closed, with an immutable `EffectiveRouterConfigSnapshot` and stable
  lowercase SHA-256 `config_generation`;
- atomic runtime-state persistence (temp + flush + replace), backup and
  quarantine receipts, versioned migration machinery with a test-only N-1
  fixture, and verified rollback;
- PID/process ownership with fingerprint verification
  (`OwnerRecord`, `IProcessInspector`, live/stale/foreign detection, no process
  killing);
- `SecretReference` validation, explicit environment allowlist, opaque
  `SecretHandle`, and rotation-safe `EnvironmentSecretResolver`.

LR-3 (Responses ingress):
- loopback-only ASP.NET Core/Kestrel ingress bound strictly to `127.0.0.1`;
- `POST /v1/responses`, `GET /health`, and `GET /v1/router/status` with exact
  path/method semantics; everything else is 404/405;
- Bearer local-router authentication via the LR-2 `SecretResolver`
  (`CODEX_LOCAL_ROUTER_TOKEN`), fixed-time comparison, and scope checks
  (`responses:invoke`, `router:status`) resolved from enabled client
  definitions;
- strict browser boundary (Origin denied by default, no wildcard CORS), Host
  validation against the loopback listener contract, and hard
  body/header/connection limits with code ceilings;
- canonical Responses V1 request parsing (text, instructions, reasoning,
  function tool data, streaming) with `unsupported_parameter` /
  `unsupported_capability` fail-closed semantics;
- canonical non-stream JSON and safe SSE writers, first-output checkpoint,
  TTFT boundary, and unified client-disconnect/deadline/shutdown cancellation;
- an `IResponsesService` execution boundary. The enabled Host path composes the
  production execution service (`Router.Execution`), which runs the real
  Route Resolver, protocol gate, Provider Adapter Registry, Provider Harness,
  and loopback/HTTPS upstream transport; `FakeResponsesService` remains a
  test-only injectable override. **When Router Mode is explicitly enabled,
  production execution may call only approved upstream HTTPS endpoints and
  resolves provider credentials at runtime through the allowlisted
  `SecretResolver`/`SecretHandle` boundary.** Provider secret values are never
  written to client configuration, never exposed to Codex CLI/Desktop, and
  never enter request logs, status, or execution metadata. The Router never
  reads `auth.json`, and Router production execution does not depend on
  project `.env`. The Router-disabled default path performs no provider
  networking and no provider-secret resolution. Tests and CI make no live
  provider requests and perform no paid inference. The default host path
  still exits safely without binding; only an explicit router-enabled config
  may start the loopback listener.

LR-4 (registries, model mapping, route resolver):
- immutable Provider Registry reusing existing Manager provider IDs
  (`chatgpt`, `mm_openai_api`, `mm_modelstudio`, `mm_openrouter`, `mm_mimo`),
  each with a non-eligible adapter placeholder until an explicit adapter
  registration exists (LR-5+);
- immutable Protocol Registry with only
  `protocol.openai.responses.v1` eligible; future protocols (for example
  Anthropic Messages) are reserved placeholders and are never selectable;
- provider-scoped Model Registry built from explicit config, enriched by a
  read-only projection of `installer/model-catalog.json` (schema v3) that never
  becomes a second catalog and never infers identity, aliases, or providers
  from model names, brands, or stealth names;
- Router Route Registry with priority/weight/health and policy references only
  (retry/failover/breaker engines remain LR-11), plus explicit endpoint
  definitions;
- a deterministic Route Resolver over an immutable `RouterRegistrySnapshot`
  bound to `config_generation`: exact/alias provider-scoped mapping, client
  authorization, enabled/health eligibility, capability intersection, lowest
  numeric priority, and stable SHA-256 weighted selection with golden tests;
- typed fail-closed errors for unknown provider/protocol/model/route/client,
  duplicates, ambiguous aliases, placeholders, capability mismatch, invalid
  endpoint references, unauthorized routes, and bad explicit preferences;
- **no provider network request, health probe, retry engine, failover
  execution, circuit breaker, protocol conversion, or paid inference exists.**

LR-5 (provider harness and fake Responses adapter):
- versioned Provider Adapter abstractions (`ProviderAdapterDescriptor`,
  `IProviderAdapter`, normalized `ProviderAdapterResult`) with exact identity
  and capabilities; no reflection discovery, no model/provider-name inference,
  no silent version upgrade;
- immutable `ProviderAdapterRegistry` with duplicate/version-collision
  rejection, exact provider identity, unsupported/placeholder fail-closed
  resolution;
- unified upstream HTTP boundary (`Router.UpstreamHttp`) owning connection
  lifecycle, HTTPS enforcement (loopback HTTP only inside tests), same-origin
  redirect policy with cross-origin/scheme-downgrade rejection, per-stage
  timeout normalization (connect/first-byte/idle/total), cancellation, and
  safe response-header allowlist extraction;
- typed `AttemptRecord`/`RetryCheckpoint` lifecycle with pre-output retry
  guard (retry forbidden after any output) and safe timing/usage metadata only;
- a loopback-only Fake Responses Provider (Kestrel fixture app) with
  deterministic scenarios: non-stream, SSE, fragmented SSE, delayed
  first-byte/chunks, timeouts, 400/401/403/404/408/409/429/500/502/503,
  malformed body, truncated stream, connection reset, redirects, cancellation,
  reasoning, tools, usage, and provider error payloads;
- a reusable **Provider Contract Kit**: LR-6/7/7A/7B adapters must pass the
  same suite by inheriting it; there is no second, weaker adapter suite;
- **no real provider adapter, provider network call, protocol conversion,
  retry/failover/breaker engine, health probe, or paid inference exists.**

LR-6 (OpenRouter provider adapter):
- exact `mm_openrouter` identity
  (`adapter.provider.mm_openrouter.responses.v1` / `1.0` /
  `protocol.openai.responses.v1`), integrated with the LR-5 Provider Harness;
- Responses-compatible request mapping with the upstream model ID taken only
  from the resolved route's explicit `upstream_model_id` (no model/provider
  inference, no aliases, no fallback);
- `OPENROUTER_API_KEY` used only through the opaque `SecretHandle` boundary
  into the minimal `Authorization: Bearer` header; explicit header allowlist,
  no client-header pass-through;
- explicit repository-approved endpoint reference with HTTPS-only production
  policy and LR-5 redirect safety (cross-origin and scheme downgrade rejected);
- non-stream, SSE, fragmented SSE, reasoning, tool call/result, usage, and
  normalized errors (400/401/403/404/408/409/429/500/502/503, malformed,
  truncated, reset, timeouts, cancellation);
- passive provider outcomes only (no health engine, no probe, no `/models`);
- **the adapter and all tests talk only to the loopback Fake OpenRouter
  Upstream; no live OpenRouter request, no paid inference, and no secret
  material exists.**

LR-10 / LR-10R (usage metering and completion substrate):
- one safe, bounded metering record per logically completed request with
  request-id keyed deduplication, normalized usage, and informational cost
  estimates projected from the canonical `installer/model-catalog.json`
  (packaged into Router.Host output/publish as one linked content file);
- a bounded completion queue with a single background consumer and a hard
  shutdown drain timeout; completed responses never wait on disk I/O and never
  fire a task per request, so an immediate Router shutdown cannot silently
  drop the final completion;
- authoritative usage identity is carried by the execution result
  (`ResponsesServiceResult.Execution`); Router.Host never infers provider or
  route identity from configuration. Without execution-carried identity the
  meter records `IdentityUnavailable` and estimates nothing;
- **execution prerequisite closed**: the production Router execution
  composition (RouterHostBootstrap → RouterExecutionServiceFactory.Create →
  RouterExecutionResponsesService → ResponsesIngress) is on `main` via PR #86
  (`ddc6e0fae0c6a1b4c87ccb7a49a3752a0334955b`). LR-10R consumes the
  authoritative `ResponsesExecutionMetadata` emitted by that real execution
  stack, so real provider execution → canonical usage → production metering is
  now wired and verified through loopback fake-upstream E2E. Router.Host no
  longer composes `FakeResponsesService`; the fake service exists only as a
  test-only injectable override. No CI test or validator ever calls a real
  paid provider.

LR-14P (control-plane contracts — corrective prerequisite for LR-14, **not** a
new official roadmap slice; formal roadmap remains 16/18):
- versioned authenticated control-plane status
  (`GET /v1/router/control-plane/status`) reusing the existing local bearer
  token boundary; `start_stop_available=false` with
  `LIFECYCLE_CONTROL_GAP` is always explicit;
- bounded Usage / Cost projection
  (`GET /v1/router/control-plane/usage`) over the exact production
  `RequestMeteringStore` instance written by `ProductionCompletionObserver`;
  unknown usage/cost stay null, never zero, costs are always informational
  estimates and summaries are grouped by currency;
- bounded safe recent-request projection
  (`GET /v1/router/control-plane/requests`) over the Router-owned durable log
  with corruption isolation and explicit degraded state;
- configured vs effective policy read
  (`GET /v1/router/control-plane/policy`) and generation-aware policy mutation
  (`PUT /v1/router/control-plane/policy`) restricted to existing LR-11 retry,
  timeout, and failover fields; absent bodies remain safe defaults and
  cross-model fallback is structurally HARD OFF;
- generation-aware Local Router feature enable/disable
  (`PUT /v1/router/control-plane/feature`) that changes the minimum
  schema-coupled feature state (`local_router.enabled` + the coupled `mode`
  marker) and nothing else, publishes the change to the running serving gate,
  and never claims process Start/Stop;
- host-independent `LocalRouterConfigOperator` with atomic writes, validation
  before write, and preservation of the previous config on failure;
- every control-plane read/mutation is authenticated, makes no provider
  request, and never exposes prompts, outputs, tool content, headers, secrets,
  endpoint URLs, filesystem paths, or raw exception text.

See `docs/LOCAL_ROUTER_LR14P_CONTROL_PLANE.md` and the control-plane `*.v1`
JSON schemas under `schemas/` for the full contract.

## Layout

```text
local-router/
  Directory.Build.props        shared build policy (nullable, warnings-as-errors, deterministic)
  Directory.Packages.props     centrally pinned test package versions
  global.json                  exact .NET SDK pin (10.0.400)
  LocalRouter.sln
  config/router.defaults.json  checked-in schema-v1 safe defaults (disabled)
  schemas/                     JSON Schema contract documentation (v1)
  src/Router.Core/             lifecycle, IDs, context, errors, cancellation
  src/Router.Configuration/    config model, merge, validation, generation, paths
  src/Router.Secrets/          SecretReference, allowlist, resolver, opaque handle
  src/Router.State/            atomic state, receipts, migration, ownership
  src/Router.ClientAdapters.Responses/  canonical Responses models, parser, service boundary
  src/Router.Ingress/          loopback Kestrel ingress, SSE, limits, auth, test-only fake service
  src/Router.CatalogProjection/  read-only v3 catalog projection (metadata only)
  src/Router.Registries/       immutable provider/protocol/model/route registries + snapshot
  src/Router.Routing/          deterministic Route Resolver, ResolvedRoute, weighted selection
  src/Router.ProviderAdapters.Abstractions/  adapter contracts, registry, harness, attempt records
  src/Router.UpstreamHttp/     unified HTTPS/loopback upstream transport + timeout stages
  src/Router.Execution/        production execution composition: snapshot, resolver, provider execution,
                               policy orchestration, authoritative ResponsesExecutionMetadata
  src/Router.ProviderAdapters.Responses/     Responses-compatible codec + TEST-ONLY fake adapter
  src/Router.ProviderAdapters.OpenRouter/    mm_openrouter Responses adapter (LR-6)
  src/Router.Host/             default-disabled executable + composition root
  tests/Router.Core.Tests/     unit + disabled-host process tests
  tests/Router.Ingress.Tests/  loopback integration, auth/origin/limits/cancellation/SSE tests
  tests/Router.Execution.Tests/  production composition E2E, retry/failover/selection safety, network guard
  tests/Router.CatalogProjection.Tests/  v3 catalog/pricing projection regression tests
  tests/Router.Registries.Tests/  registry invariant and fail-closed tests
  tests/Router.Routing.Tests/  resolver table/golden tests + deterministic weight tests
  tests/Router.TestSupport/    deterministic LR-4 test config factory
  tests/Router.FakeProvider/   loopback-only fake upstream fixture app (Kestrel)
  tests/ProviderContractKit/   reusable Provider Contract Kit + network guard
  tests/Router.ProviderAdapters.Tests/  fake adapter contract + transport/security/timeout tests
  tests/Router.ProviderAdapters.OpenRouter.Tests/  OpenRouter contract kit + identity/mapping/secret tests
  tests/fixtures/...           static LR-1/LR-2 test fixtures (repo root)
```

## Build and test

```powershell
dotnet restore local-router/LocalRouter.sln
dotnet build local-router/LocalRouter.sln --configuration Release
dotnet test local-router/LocalRouter.sln --configuration Release
```

## Safety properties (LR-1)

- `Router.Host` prints a DISABLED marker and exits with code 0 immediately.
- No TCP/HTTP bind, no Kestrel startup, no provider API, no secret access.
- No `.env`, `auth.json`, `~/.codex`, Manager state, or Codex config access.
- All transitions are compare-and-set; terminal states are immutable except the
  single documented recovery path.

## Safety properties (LR-2)

- Defaults are `mode=direct`, `local_router.enabled=false`, host `127.0.0.1`.
- Host default startup reads only checked-in defaults; it never resolves
  secrets, never writes state, and never binds a listener.
- Config merge and validation fail closed on unknown fields, unknown schema,
  invalid hosts/ports/limits, duplicate IDs, and unknown enums.
- State writes are atomic; corrupt state is quarantined, never deleted.
- Ownership detection never kills processes; stale records are archived.
- Secret resolution is allowlisted, uncached (rotation-safe), and never
  serializes values.

## Stack decision

The exact SDK, target framework, runtime strategy, package policy, CI, nullable,
analyzer, cancellation, SSE, and single-file decisions are recorded in
[docs/adr/LOCAL_ROUTER_RUNTIME_STACK.md](../docs/adr/LOCAL_ROUTER_RUNTIME_STACK.md).

## DeepSeek Official direct provider (DSR2 compatibility phase)

The Local Router bootstraps the DeepSeek Official provider identity (`deepseek`)
next to the existing providers:

| Layer | Identity | Notes |
| --- | --- | --- |
| Canonical catalog | `deepseek::deepseek-flash`, `deepseek::deepseek-v4-pro` | provider-scoped; the Model Studio records `modelstudio::deepseek-v4-pro` and `modelstudio::deepseek-v4-flash` stay untouched and inactive |
| Approval registry | `(provider_id, model_id)` | the same model id may be approved once per provider - a duplicate model id is not a catalog conflict |
| Client-facing slug | exactly one active owner per client | a slug claimed by two enabled routes fails closed with `CLIENT_MODEL_SLUG_COLLISION`; never first/last wins, priority, weight, or random |

Current compatibility phase: the Codex native picker catalog
(`~/.codex/models.json`) still contains the legacy slugs `deepseek-v4-flash`,
`deepseek-v4-pro`, and `deepseek-v4-flash-vision-exp`. The Router keeps them
routable through the explicit, versioned model-route alias table:

```text
picker legacy slug            -> Router model-route identity -> canonical upstream model id
deepseek-v4-flash             -> alias of model-route.deepseek-deepseek-flash -> deepseek-flash
deepseek-v4-flash-vision-exp  -> alias of model-route.deepseek-deepseek-flash -> deepseek-flash
deepseek-flash                -> client_model_id of that route             -> deepseek-flash
deepseek-v4-pro               -> client_model_id of model-route.deepseek-deepseek-v4-pro -> deepseek-v4-pro
```

Client identity and upstream identity are deliberately separate: the canonical
upstream model id is what the DeepSeek endpoint receives, while the
client-facing slug is what Codex sends. DSR2 never edits the picker catalog and
never activates a provider route by itself - the approval gate
(`candidate -> probe -> approve -> Router`) still applies.

Future NMP1 (picker catalog promotion) must add the canonical entries
`deepseek-flash` (DeepSeek V4.1 Flash) and `deepseek-v4-pro` (DeepSeek V4 Pro)
to the native picker catalog with real metadata before the legacy picker entries
can be retired; until then the alias table above is the compatibility path.
