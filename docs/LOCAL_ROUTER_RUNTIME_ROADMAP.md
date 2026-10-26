# Local Router Runtime Roadmap

Status: **implementation roadmap; LR-0 only is in scope for this change**

Roadmap version: `local-router-roadmap/v1`

## Delivery rules

Each LR slice is one independently reviewable PR. Slices are merged in dependency order; no PR may smuggle work from a later slice. Direct Mode remains the default throughout. Router remains disabled until a user explicitly enables it after the applicable integration and release gates.

Contract interfaces use language-neutral pseudotypes. The planned implementation substrate is **C# + ASP.NET Core**, but LR-0 does not lock an exact supported .NET LTS SDK/runtime or package version. The LR-1 ADR must decide and pin the exact SDK, runtime, and package versions after toolchain, license, Windows CI, single-file distribution, cancellation, and SSE checks. This architecture PR installs nothing and adds no runtime files.

### Obligations inherited by every slice

Every slice card below supplements these non-negotiable fields:

- **Responsibilities / inputs / outputs / core entities / schema / ID / version:** only the components and `contracts/v1` entities assigned to the slice; no unversioned public type.
- **States / checkpoints:** use the lifecycle, route-health, request, breaker, migration, and atomic-state contracts; request content is never a checkpoint.
- **Dependencies:** use interfaces, never reach across Provider/Protocol/Secret boundaries.
- **Errors / retry / timeout / idempotency / cancellation:** explicitly exercise the applicable matrices; defaults remain safe and cancellation-aware.
- **Trace / permissions / secrets:** typed allowlist records only, local scopes only, references/opaque handles only.
- **Migration / feature flag / rollback:** versioned, backup-preserving, idempotent; `mode=direct`, `local_router.enabled=false`, cross-model fallback OFF unless the slice explicitly and safely changes an opt-in path.
- **Test levels:** unit, contract, fake-upstream integration, Direct Mode regression, versioned golden fixture/eval as applicable. No real provider, paid inference, user key, user config, `auth.json`, or project `.env`.
- **Release gate:** local canonical validation, slice validation, secret/runtime-state scan, protected Direct Mode regression, diff review, and actual Development Gate CI success before merge. A local run cannot be reported as CI PASS.
- **Out of scope:** remote listening, Chat ingress/active `wire_api = "chat"`, implicit model identity, tool execution, silent semantic loss, automatic cross-model fallback, and unrelated V4/Desktop/Direct Mode work.

If any inherited field is not applicable, the PR design card must say `N/A` with a reason; blank is NOT READY.

## Build order

```text
LR-0 Architecture Gate
  -> LR-1 Core Skeleton
  -> LR-2 Configuration, State, Secret Boundary
  -> LR-3 Responses Ingress
  -> LR-4 Registries, Mapping, Resolver
  -> LR-5 Provider Harness + Fake Responses Adapter
     -> LR-6 OpenRouter Adapter
     -> LR-7 Model Studio Adapter
     -> LR-7A OpenAI API Adapter
     -> LR-7B Xiaomi MiMo Adapter
  -> LR-8 Protocol Adapter Boundary
  -> LR-9 Health, Trace, Logs
  -> LR-10 Usage and Cost
  -> LR-11 Policy, Retry, Failover, Circuit Breaker
  -> LR-12 Codex CLI Integration
  -> LR-13 Codex Desktop Integration
  -> LR-14 V4 UI Integration
  -> LR-15 Hardening and Release
```

Provider adapter PRs LR-6, LR-7, LR-7A, and LR-7B may be developed after LR-5 but must remain separate PR boundaries and merge one at a time so failures and rollback are provider-scoped. LR-12 through LR-14 require LR-15 pre-release evidence before Router is advertised as generally ready.

## LR-0 — Architecture Gate

| Field | Contract |
|---|---|
| **Goal** | Establish Level 3 boundaries, schemas, state machines, security rules, build order, static enforcement, and protected Direct Mode files without runtime implementation. |
| **Inputs** | `AGENTS.md`, README/docs, installer/Skill Provider code, model catalog v3, Direct/Desktop launch scripts, tests, CI workflow, user constraints. |
| **Outputs** | Three normative architecture documents and a non-network static validator wired into Development Gate. |
| **Files** | `docs/LOCAL_ROUTER_RUNTIME_{ARCHITECTURE,CONTRACTS,ROADMAP}.md`, `tests/validate-local-router-architecture.ps1`, `docs/README.md`, `.github/workflows/ci.yml`. No production file. |
| **Dependencies** | Current clean `main`; existing `tests/validate-repo.ps1`; no runtime/toolchain dependency. |
| **Tests** | Static required-file/section/invariant checks; repository gate; manual diff/search for forbidden production edits, secrets, destructive Git, and legacy Chat wire mode. |
| **Out of Scope** | Any server, localhost bind, provider/API call, dependency install, Codex config, Direct/Desktop/V4 change, runtime state. |
| **Definition of Ready** | Repository clean; real branch/HEAD/docs inspected; Direct Mode and pricing/provider identities understood; architecture task explicitly authorized. |
| **Definition of Done** | All required Level 3 fields have normative sources; validator passes locally; canonical repo validation passes; only architecture/CI files changed; diff reviewed. |
| **Rollback** | Revert this documentation/static-test commit; no user/runtime/config state exists to restore. |
| **PR Boundary** | Architecture and static gate only. Must not be combined with LR-1 code. |

## LR-1 — Router Core Skeleton and Lifecycle

| Field | Contract |
|---|---|
| **Goal** | Create compileable/testable Router core abstractions, lifecycle machine, IDs, normalized errors, cancellation propagation, and feature-disabled executable skeleton; no listening socket. |
| **Inputs** | LR-0 contracts, implementation-substrate ADR, fake clock/ID interfaces. |
| **Outputs** | Core library, no-op host that exits disabled, immutable request/config contexts, lifecycle/error unit tests. |
| **Files** | planned `local-router/README.md`, `local-router/Directory.Build.props`, `local-router/src/Router.Core/`, `local-router/src/Router.Host/`, `local-router/tests/Router.Core.Tests/`, `docs/adr/LOCAL_ROUTER_RUNTIME_STACK.md`. |
| **Dependencies** | LR-0; approved/pinned .NET LTS and licenses; CI cache/build design. |
| **Tests** | Unit transition table including forbidden transitions; UUID/size tests; cancellation races; error golden schema; executable proves disabled/no bind; Direct Mode regression. |
| **Out of Scope** | HTTP ingress, config mutation, provider adapter, secret resolution, user service install. |
| **Definition of Ready** | Stack ADR accepted; exact contract/version namespaces and package ownership approved; SDK available in CI; no protected file edit. |
| **Definition of Done** | Skeleton builds deterministically; default process cannot bind or serve; all terminal transitions are compare-and-set; tests and CI pass. |
| **Rollback** | Remove standalone `local-router/` skeleton and CI build step; Direct Mode remains untouched. |
| **PR Boundary** | Core types/lifecycle/host bootstrap only; no network or Provider code. |

## LR-2 — Configuration, State, Secrets, and Ownership

| Field | Contract |
|---|---|
| **Goal** | Implement schema-v1 defaults/user merge, validation, atomic state, migration/rollback receipts, PID ownership, and environment Secret Resolver behind opaque handles. |
| **Inputs** | `RouterConfig`, `SecretReference`, runtime-state schemas; existing Manager home and backup conventions. |
| **Outputs** | immutable config snapshot/generation, disabled checked-in defaults, safe user paths, stale-PID detection, fake/environment resolver. |
| **Files** | planned `local-router/config/router.defaults.json`, `local-router/schemas/*.schema.json`, `local-router/src/Router.Configuration/`, `Router.Secrets/`, `Router.State/`, tests/fixtures. |
| **Dependencies** | LR-1 lifecycle/errors/IDs; OS ACL/atomic-replace abstraction. |
| **Tests** | Default disabled; host rejects non-loopback; duplicate/unknown schema; N-1 migration/idempotency/corruption/rollback; PID live/stale fingerprint; missing/scope/rotation; opaque handle cannot stringify; golden receipts. |
| **Out of Scope** | Secret store, key generation, `.env` reads, Router HTTP bind, Codex config, provider call. |
| **Definition of Ready** | File locations/ACL threat model approved; migration N-1 fixtures committed; environment reference allowlist decided. |
| **Definition of Done** | Atomic/recoverable writes verified on Windows; corrupt config leaves Router disabled; no secret value serialized; no live process killed; regression/CI pass. |
| **Rollback** | Stop disabled skeleton; restore verified config/state backup by receipt; preserve quarantined corrupt file; return Direct Mode. |
| **PR Boundary** | Control-plane persistence/secret interface only; no HTTP/upstream transport. |

## LR-3 — OpenAI Responses Ingress

| Field | Contract |
|---|---|
| **Goal** | Implement loopback-only authenticated `POST /v1/responses`, `/health`, and `/v1/router/status` with parsing, SSE writer, limits, browser boundary, and transport cancellation against a fake core. |
| **Inputs** | canonical Responses fixtures, client definitions/scopes, core context/error/cancellation, config host/port. |
| **Outputs** | Client Ingress and Codex-neutral Responses client adapter; no real provider route. |
| **Files** | planned `local-router/src/Router.Ingress/`, `Router.ClientAdapters.Responses/`, ingress schemas, tests/fixtures under `tests/fixtures/local-router/v1/responses/`. |
| **Dependencies** | LR-1 and LR-2; loopback bind/ownership complete. |
| **Tests** | Auth/Host/Origin/CORS/body/header/connection limits; exact paths/methods; non-stream and fragmented SSE; reasoning/tool round trip; multimodal/background rejection; TTFT; disconnect/deadline/shutdown cancellation; port conflict; fake integration only. |
| **Out of Scope** | Provider network, protocol conversion, explicit background cancel endpoint, remote bind, browser UI. |
| **Definition of Ready** | Canonical fixture license/provenance accepted; auth capability provision procedure designed; default port conflict behavior approved. |
| **Definition of Done** | Only `127.0.0.1` can bind; protected endpoints deny missing auth; public health is minimal; first-byte retry checkpoint emitted; no request content logged; tests/CI pass. |
| **Rollback** | Disable feature and remove ingress package/host wiring; no Codex client points at it yet. |
| **PR Boundary** | Ingress/client protocol only, backed by fake response service. |

## LR-4 — Registries, Model Mapping, and Route Resolver

| Field | Contract |
|---|---|
| **Goal** | Implement immutable Provider/Protocol/Model/Route registries and deterministic resolver while reusing Manager Provider IDs and model catalog projection. |
| **Inputs** | config generation; current `installer/model-catalog.json` projection; client/capability/health snapshots. |
| **Outputs** | validated registry snapshot and exact `ResolvedRoute`; no upstream request. |
| **Files** | planned `local-router/src/Router.Routing/`, `Router.Registries/`, `Router.CatalogProjection/`, schemas and routing fixtures. Existing model catalog remains unchanged initially. |
| **Dependencies** | LR-1/LR-2; protocol/provider descriptors can be placeholders but cannot be eligible. |
| **Tests** | Exact/alias/provider-scoped mapping; priorities; deterministic weights; disabled/unhealthy/unknown; capability intersection; ambiguity; placeholder rejection; stealth no-inference; V4 schema-v3 price/model projection; golden resolved routes. |
| **Out of Scope** | New model approval, V4 catalog edits, provider call, health probes, failover execution. |
| **Definition of Ready** | Provider identity mapping reviewed with Direct Mode owners; merge/precedence and alias rules accepted. |
| **Definition of Done** | No second model world; all selections explainable/auditable; unsupported/ambiguous fails closed; immutable generation used per request; regression/CI pass. |
| **Rollback** | Remove projection/resolver wiring; feature remains disabled; source catalog unchanged. |
| **PR Boundary** | Pure registry/resolver logic and local catalog projection only. |

## LR-5 — Provider Harness and Fake Responses Adapter

| Field | Contract |
|---|---|
| **Goal** | Build Provider Adapter registry/harness, upstream HTTP boundary, timeout/retry attempt orchestration, and a loopback fake Responses adapter before any vendor adapter. |
| **Inputs** | `ResolvedRoute`, opaque secret handle, canonical request, deadline/cancellation, fake endpoint fixtures. |
| **Outputs** | adapter descriptor/conformance kit, attempt records, normalized response/event/error; fake adapter only. |
| **Files** | planned `local-router/src/Router.ProviderAdapters.Abstractions/`, `Router.UpstreamHttp/`, `local-router/tests/ProviderContractKit/`, fake upstream fixture app. |
| **Dependencies** | LR-1 through LR-4. |
| **Tests** | Adapter registration/version collision; TLS policy except test loopback; redirects; header redaction; connect/first-byte/idle/total timeout; safe pre-output retry; no post-output retry; cancellation; tool/reasoning/usage/error contract kit. |
| **Out of Scope** | Real vendor URL/key/request; protocol conversion; cross-route failover; production adapter. |
| **Definition of Ready** | Adapter descriptor and fake server interfaces frozen at v1; deterministic network clock strategy approved. |
| **Definition of Done** | A provider adapter can pass the full contract kit using only fake upstream; Core exclusively owns retry/cancel; sinks cannot receive raw headers/content; CI pass. |
| **Rollback** | Remove isolated harness packages; ingress returns no eligible route; Direct Mode unaffected. |
| **PR Boundary** | Generic upstream/fake adapter infrastructure only. |

## LR-6 — OpenRouter Provider Adapter

| Field | Contract |
|---|---|
| **Provider Implementation** | `mm_openrouter` |
| **Goal** | Implement `mm_openrouter` Responses-compatible adapter using only `OPENROUTER_API_KEY` reference and explicit configured endpoint. |
| **Inputs** | LR-5 harness, OpenRouter canonical golden captures scrubbed of content/secrets, existing Manager provider identity/base URL reference. |
| **Outputs** | versioned adapter descriptor, request/header mapping, SSE/usage/error normalization, passive health outcomes. |
| **Files** | planned `local-router/src/Router.ProviderAdapters.OpenRouter/`, provider fixtures and contract tests; no Direct/V4/Desktop files. |
| **Dependencies** | LR-5; LR-4 mapping; explicit endpoint allowlist. |
| **Tests** | Contract kit; fake 2xx/4xx/429/5xx; Responses events, reasoning/tools/usage; missing/rotated secret; redirect denial; cancellation; no-content/redaction; same-route retry boundary. No live API. |
| **Out of Scope** | `/models` discovery, live/paid probe, auto-approval, alternate provider/model fallback, Ox identity inference. |
| **Definition of Ready** | Public Responses behavior documented in scrubbed fixtures; adapter capability truth table reviewed; no paid test authorized/required. |
| **Definition of Done** | Full fake conformance; exact `mm_openrouter` identity; value never leaves secret handle/HTTP auth boundary; feature still disabled by default; CI pass. |
| **Rollback** | Disable/remove adapter registration; routes become unavailable with safe reason; Direct OpenRouter mode remains unchanged. |
| **PR Boundary** | One provider adapter only. |

## LR-7 — Alibaba Model Studio Provider Adapter

| Field | Contract |
|---|---|
| **Provider Implementation** | `mm_modelstudio` |
| **Goal** | Implement `mm_modelstudio` for configured Responses-compatible Model Studio endpoints and `CODEX_DASHSCOPE_API_KEY` reference. |
| **Inputs** | LR-5 contract kit, existing provider/base URL reference, scrubbed Responses fixtures for Qwen/DeepSeek-hosted models. |
| **Outputs** | versioned adapter descriptor and normalized fake-tested behavior. |
| **Files** | planned `local-router/src/Router.ProviderAdapters.ModelStudio/` and provider fixtures/tests. |
| **Dependencies** | LR-5 and LR-4; workspace endpoint URL validator. |
| **Tests** | Contract kit; URL/template validation without arbitrary interpolation; SSE/tools/reasoning/usage/errors; timeout/cancel/retry; secret missing/scope/rotation; model/provider identity remains separate. |
| **Out of Scope** | Chat-only Coding Plan conversion, live endpoint/model discovery, paid probe, direct Qwen/DeepSeek adapter, V4 edits. |
| **Definition of Ready** | Supported Responses endpoint shapes and capability gaps documented; fixture provenance/scrubbing approved. |
| **Definition of Done** | Only explicit Responses-compatible endpoints accepted; no model-brand-to-provider inference; fake contract and regression/CI pass. |
| **Rollback** | Remove/disable `mm_modelstudio` adapter/routes; existing Direct Model Studio flow remains available. |
| **PR Boundary** | Model Studio provider only. |

## LR-7A — OpenAI API Provider Adapter

| Field | Contract |
|---|---|
| **Provider Implementation** | `mm_openai_api` |
| **Goal** | Implement only the `mm_openai_api` Responses-compatible adapter without treating ChatGPT account authentication as an upstream Router secret. |
| **Inputs** | LR-5 contract kit; `CODEX_OPENAI_API_KEY` reference; repository-approved OpenAI API endpoint reference and scrubbed Responses fixtures. |
| **Outputs** | One versioned `mm_openai_api` adapter descriptor, request/header mapping, SSE/usage/error normalization, and passive health outcomes; `chatgpt` remains `DIRECT_ONLY`. |
| **Files** | planned `local-router/src/Router.ProviderAdapters.OpenAI/` and `local-router/tests/Router.ProviderAdapters.OpenAI.Tests/` with OpenAI-only fixtures. |
| **Dependencies** | LR-5 provider harness; LR-4 identities/mapping; LR-2 secret scoping. |
| **Tests** | Full fake contract kit; account-auth rejection and no `auth.json`; streaming/tools/reasoning/usage/errors; timeout/cancellation/retry; missing/rotated secret; endpoint/redirect validation; no live API. |
| **Out of Scope** | Xiaomi MiMo, ChatGPT subscription/account proxy, auth-file access, model discovery/approval, live or paid inference, alternate-provider fallback. |
| **Definition of Ready** | API-provider versus ChatGPT account-provider distinction is reviewed; OpenAI-only fixtures are scrubbed and capability truth table is approved. |
| **Definition of Done** | Registry resolves only `mm_openai_api`; `chatgpt` cannot resolve to this adapter; fake conformance and Direct account regression pass; feature remains disabled by default; CI passes. |
| **Rollback** | Disable/remove only the `mm_openai_api` adapter registration; routes become unavailable safely; ChatGPT and OpenAI Direct Mode remain unchanged. |
| **PR Boundary** | One independent PR for the OpenAI API Provider Adapter only; it must not implement or register Xiaomi MiMo. |

## LR-7B — Xiaomi MiMo Provider Adapter

| Field | Contract |
|---|---|
| **Provider Implementation** | `mm_mimo` |
| **Goal** | Implement only the `mm_mimo` Responses-compatible adapter using `MIMO_API_KEY` reference and an explicit configured MiMo endpoint. |
| **Inputs** | LR-5 contract kit; `MIMO_API_KEY` reference; configured MiMo endpoint reference and scrubbed MiMo Responses fixtures. |
| **Outputs** | One versioned `mm_mimo` adapter descriptor, endpoint mapping, SSE/usage/error normalization, and passive health outcomes. |
| **Files** | planned `local-router/src/Router.ProviderAdapters.MiMo/` and `local-router/tests/Router.ProviderAdapters.MiMo.Tests/` with MiMo-only fixtures. |
| **Dependencies** | LR-5 provider harness; LR-4 identities/mapping; LR-2 secret scoping and endpoint-reference validation. |
| **Tests** | Full fake contract kit; configured endpoint variants; streaming/tools/reasoning/usage/errors; timeout/cancellation/retry; missing/rotated secret; redirect and cross-secret isolation; no live API. |
| **Out of Scope** | OpenAI API, ChatGPT account auth, automatic endpoint selection, model discovery/approval, live or paid inference, alternate-provider fallback. |
| **Definition of Ready** | MiMo endpoint reference shapes and capabilities are reviewed; MiMo-only fixtures are scrubbed; secret scope is approved. |
| **Definition of Done** | Registry resolves only `mm_mimo`; exact endpoint/secret scope is enforced; fake conformance and Direct MiMo regression pass; feature remains disabled by default; CI passes. |
| **Rollback** | Disable/remove only the `mm_mimo` adapter registration; routes become unavailable safely; existing Direct MiMo flow remains unchanged. |
| **PR Boundary** | One independent PR for the Xiaomi MiMo Provider Adapter only; it must not implement or register OpenAI API. |

## LR-8 — Protocol Adapter Boundary

| Field | Contract |
|---|---|
| **Goal** | Freeze and implement the Responses-to-Responses protocol adapter/conformance suite and placeholder registry for future Anthropic/provider protocols, without conversion code. |
| **Inputs** | canonical golden set, provider capability descriptors, Responses ingress/upstream events. |
| **Outputs** | exact pass-through/normalization adapter, semantic-loss detector, versioned protocol descriptors, unusable future placeholders. |
| **Files** | planned `local-router/src/Router.ProtocolAdapters.Abstractions/`, `Router.ProtocolAdapters.Responses/`, fixtures and capability matrix docs. |
| **Dependencies** | LR-3/LR-5 and at least one provider adapter fixture set. |
| **Tests** | Byte/semantic golden comparisons for text, SSE, reasoning, tool calls/results, usage, errors, cancellation, unsupported multimodal; placeholder cannot register as eligible; no Chat wire marker. |
| **Out of Scope** | Anthropic Messages, Chat Completions, provider-specific conversion, lossy mode. |
| **Definition of Ready** | Canonical event vocabulary and loss-policy enum stable; fixture update review policy accepted. |
| **Definition of Done** | Exact mappings pass; semantic gaps fail closed; future placeholders advertise no usable capability; CI/static legacy-wire check pass. |
| **Rollback** | Revert protocol package/version registration; provider routes are unavailable rather than downgraded. |
| **PR Boundary** | Responses-compatible protocol boundary only. |

## LR-9 — Health, Trace, and Request Log

| Field | Contract |
|---|---|
| **Goal** | Implement local startup/readiness, passive route health, typed traces/logs, redaction, retention/rotation, and authenticated status. |
| **Inputs** | lifecycle/route/attempt events, adapter outcomes, config limits; never raw content. |
| **Outputs** | `HealthSnapshot`, redacted `RequestRecord`, bounded trace, route health transitions, safe status response. |
| **Files** | planned `local-router/src/Router.Health/`, `Router.Observability/`, redaction schemas, security fixtures. |
| **Dependencies** | LR-2 state, LR-3 status endpoint, LR-5 attempt events. |
| **Tests** | Health transition thresholds/cooldown; no paid/startup network; allowed-field snapshots; forbidden prompt/tool/image/header/key/project fields; redaction failure drops event; rotation/ACL/corrupt log; public vs authenticated health. |
| **Out of Scope** | Telemetry export, browser dashboard, prompt capture, billing API, active paid health probe. |
| **Definition of Ready** | Data classification/retention defaults reviewed; health threshold policy versioned; safe reason codes frozen. |
| **Definition of Done** | Every sink accepts only redacted type; public health minimal; passive outcomes deterministic; logs contain no content/secrets; fake integration and CI pass. |
| **Rollback** | Disable durable logging/passive health, retain minimal lifecycle health; archive safe logs only by explicit user action. |
| **PR Boundary** | Local observability/health only; no pricing/failover UI. |

## LR-10 — Usage and Cost

| Field | Contract |
|---|---|
| **Goal** | Normalize provider usage, project versioned V4 pricing, and estimate costs; informational only, never billing truth. |
| **Inputs** | provider usage/attempts, `installer/model-catalog.json` v3 projection, pricing snapshot. |
| **Outputs** | `UsageRecord`, `ModelPricing`, `ProviderPricing`, `CostEstimate`. |
| **Files** | planned `Router.Metering/`, pricing projection/fixtures; existing V4 catalog unchanged unless a separate approved schema PR is required. |
| **Dependencies** | LR-4 resolver, LR-5 attempts, LR-9 traces; provider adapter usage mappings. |
| **Tests** | Decimal calculations; cached/unknown/stale/partial/currency cases; source/version/effective date; missing usage stays null/estimated=false; unknown price never equals zero. |
| **Out of Scope** | Billing guarantee/reconciliation, price auto-fetch, cost-based routing, policy enablement, UI. |
| **Definition of Ready** | Pricing projection mapping reviewed by V4 owner; pricing snapshot/version source approved. |
| **Definition of Done** | Unknown price never equals zero; estimates cite snapshot; usage fields remain null/estimated=false when absent; CI pass. |
| **Rollback** | Disable meters only; no policy/client changes; Direct Mode unaffected. |
| **PR Boundary** | Usage/cost metadata only; no policy engine or client enablement. |

## LR-11 — Policy, Retry, Failover, and Circuit Breaker

| Field | Contract |
|---|---|
| **Goal** | Implement retry, timeout, failover, and circuit breaker policies with conservative defaults; cross-model fallback remains OFF. |
| **Inputs** | route policies, attempt/outcome events, deterministic clock/random source. |
| **Outputs** | retry/failover decisions; optional breaker states. |
| **Files** | planned `Router.Policies/`, `Router.CircuitBreaker/`, policy fixtures. |
| **Dependencies** | LR-4 resolver, LR-5 attempts, LR-9 traces. |
| **Tests** | All retry statuses/deadlines; four failover classes; OFF defaults; no post-output fallback; breaker transitions; deterministic weighted choice; golden decisions. |
| **Out of Scope** | Billing, price auto-fetch, cost-based routing, automatic alternate-provider/cross-model enablement, UI. |
| **Definition of Ready** | Failover equivalence/security checklist approved; policy defaults frozen. |
| **Definition of Done** | Retry bounded/idempotent; breaker disabled unless explicit; cross-model fallback OFF in defaults/schema/tests; CI pass. |
| **Rollback** | Disable policies/breaker; fall back to one attempt on explicitly resolved route, not another model; Direct Mode unaffected. |
| **PR Boundary** | Control policies only; no usage/cost metering, client integration, or default enablement. |

## LR-12 — Codex CLI Adapter and Opt-in Integration

| Field | Contract |
|---|---|
| **Goal** | Add a separate Router-owned Codex CLI profile/config projection and ModeSelector integration while preserving existing CLI Direct Mode byte-for-byte/behaviorally as default. |
| **Inputs** | ready Router/status, explicit user enable action, backup/ownership manifest, client token reference, selected route/model. |
| **Outputs** | opt-in CLI Router profile pointing to `http://127.0.0.1:<port>/v1`; exact restore path; Direct Mode option remains default. |
| **Files** | planned new adapter/integration scripts and profile template plus tests/docs. Any touch to `launch-controller-model.ps1` requires explicit approval and the smallest additive dispatch hook; no route logic rewrite. |
| **Dependencies** | LR-1 through LR-11; Router pre-release gate; Codex Responses custom-provider compatibility fixture. |
| **Tests** | Generated config golden uses Responses only and local token env ref; backup/ownership/idempotent enable/disable/corrupt rollback; Router absent/fails/port conflict leaves Direct Mode; CLI fake end-to-end; protected launch regression. |
| **Out of Scope** | Desktop/V4 integration, default Router enablement, upstream secret exposure, model auto-switch. |
| **Definition of Ready** | Explicit UX/confirmation copy and managed-block ownership reviewed; Router status contract stable; rollback test proves exact prior config. |
| **Definition of Done** | User can opt in/out without losing unrelated config; client sees only local token; Direct remains default and works with Router absent; no paid call; CI pass. |
| **Rollback** | Stop Router profile selection, restore exact backed-up/owned config, set Router disabled/mode direct; do not delete user secrets/state automatically. |
| **PR Boundary** | Codex CLI client only; no Desktop or V4 UI. |

## LR-13 — Codex Desktop Adapter and Opt-in Integration

| Field | Contract |
|---|---|
| **Goal** | Add a separate explicit Desktop Router route/new-session flow while preserving current third-party Direct Desktop routing and exact backup/restore semantics. |
| **Inputs** | ready Router/status, explicit confirmation, Desktop integration capability evidence, existing Desktop route state/backup boundary. |
| **Outputs** | Router-specific Desktop adapter, restart/new-conversation guidance, one rollback owner, clear route status. |
| **Files** | planned new Desktop Router adapter/scripts/tests/docs. Existing `desktop-chat-provider.ps1` and generic/current route behavior are protected; any minimal integration hook requires separate review. |
| **Dependencies** | LR-12 patterns plus stable Router release candidate; Desktop sandbox/config behavior verified without real provider. |
| **Tests** | Temp `CODEX_HOME` only; exact original config/.env preservation; repeated activation idempotency; route-to-route switch keeps first rollback; missing Router/secret/port conflict; restore; Direct third-party and ChatGPT regressions. |
| **Out of Scope** | Patching official Desktop, injecting official model picker, hot-switching existing thread, V4 UI, default Router. |
| **Definition of Ready** | Desktop behavior/version evidence and threat model reviewed; backup owner conflict resolution specified; user explicitly authorizes implementation slice. |
| **Definition of Done** | Opt-in only; full restart/new thread required; current Direct Desktop route still works; exact restore proven; no upstream key copied to client config; CI pass. |
| **Rollback** | Use verified first backup to restore Desktop configuration, disable Router adapter, require restart/new thread; preserve current Direct route tooling. |
| **PR Boundary** | Desktop integration only; no V4 presentation change. |

## LR-14 — V4 UI Integration

> **LR-14P prerequisite**: the corrective prerequisite integration work
> (`feat/local-router-lr14-control-plane-contracts`) is NOT a new official
> roadmap slice and does not advance the formal roadmap beyond 16/18. It
> provides the versioned control-plane contracts the V4 UI consumes in LR-14.
> Lifecycle Start/Stop ownership remains a documented gap owned by LR-15.

| Field | Contract |
|---|---|
| **Goal** | Present Direct/Router mode, Router lifecycle/health, safe usage/cost, and explicit policy controls without changing existing catalog/provider semantics. |
| **Inputs** | authenticated redacted status/observability contracts; existing catalog hierarchy/price basis; explicit user actions. |
| **Outputs** | additive V4 controls and status; Router disabled by default; safe errors and rollback affordance. |
| **Files** | V4 files only in this future PR plus dedicated UI tests/docs; no Router core/provider implementation. Exact files determined from current V4 owner modules at LR-14 start. |
| **Dependencies** | LR-9/LR-10/LR-11 and at least CLI integration; actual status API stable. |
| **Tests** | UI default Direct/disabled; no prompt/key/base-url leak; unknown/stale/partial cost labels; health states; cross-model fallback OFF and explicit warning; Router absent; accessibility/layout; existing V4 catalog/sort/card regression. |
| **Out of Scope** | Core routing changes, provider adapters, price auto-fetch, Desktop integration, silent config writes. |
| **Definition of Ready** | V4 design/owner approval; status schema pinned; accessibility and localization strings ready; no architecture ambiguity. |
| **Definition of Done** | UI is a client of redacted contracts; Direct default unchanged; explicit actions use backup/rollback path; existing V4 validations plus new tests and CI pass. |
| **Rollback** | Remove/hide additive Router controls via feature flag; no core/config migration reversal required; Direct V4 remains. |
| **PR Boundary** | Presentation/integration only. This architecture PR must not modify V4 UI. |

## LR-15 — Hardening, Packaging, and Release

| Field | Contract |
|---|---|
| **Goal** | Prove security, reliability, packaging, install/upgrade/rollback, resource limits, and release readiness while keeping Router optional. |
| **Inputs** | all prior slice artifacts, threat model, dependency/SBOM data, deterministic test matrix, release candidate packages. |
| **Outputs** | signed/versioned package plan, install/uninstall/upgrade docs, operational limits, support matrix, release and rollback evidence. |
| **Files** | packaging/installer additions, release docs, SBOM/license files, hardening tests; production edits require explicit review and are not part of LR-0. |
| **Dependencies** | LR-1 through required integration slice(s); Windows CI; security review. |
| **Tests** | Full unit/contract/fake integration/regression/golden/eval; load/backpressure/cancel/shutdown/crash/stale PID/port conflict/corruption/migration; ACL/redaction/CSRF/local-auth; dependency and secret scans; clean-machine package test. Live paid provider eval remains separately confirmed. |
| **Out of Scope** | Remote multi-user service, automatic cross-model fallback, billing guarantees, unsupported protocols/capabilities, merge with failing CI. |
| **Definition of Ready** | Zero unresolved critical security/contract issues; support/deprecation/rollback policy approved; live paid eval decision explicitly recorded. |
| **Definition of Done** | Actual Development Gate and release matrix succeed; package reproduces; Direct Mode regression succeeds; rollback drill succeeds; Router still opt-in; known limitations published. |
| **Rollback** | Stop/disable Router, restore exact owned client config, uninstall only Router-owned package/files, preserve logs/state unless explicitly removed, continue Direct Mode. |
| **PR Boundary** | Hardening/packaging/release evidence only; feature expansion requires new roadmap. |

### LR-15 status — PR6 release package and provenance (implemented)

What exists now (verified locally and by the Development Gate, offline):

- `installer/scripts/build-release-package.ps1` builds a versioned release
  package from ONE commit of a real checkout. Content is exported with
  `git archive` from that commit, so uncommitted edits, local runtime state and
  user configuration can never leak into a package; the source commit must
  resolve in the source repository and must be its HEAD.
- The package carries `release-manifest.json` with the product name, version,
  source commit, `source_dirty`, build time, the packaged file list with size and
  per-file SHA256, the recorded entry points and a package-wide digest.
- Packaging uses an explicit allow list (product directories plus the root
  product documents). A file matching the sensitive/excluded patterns
  (`.env*`, `auth.json`, `state.json`, `*.key`, `*.pem`, `*.sqlite`, `.git/**`,
  `.github/**`, `bin/**`, `obj/**`, backups/handoffs/reports) makes the builder
  REFUSE to produce a package instead of silently dropping it.
- `-Verify` re-reads every packaged byte, recomputes the hashes, rejects missing
  files, modified content, a forged per-file SHA256, unlisted extra files, a
  wrong file count and a wrong package digest, and can resolve the recorded
  source commit against a source repository.
- `tests/validate-release-package-provenance.ps1` proves scenarios A-L offline
  against synthetic git repositories and is executed by `tests/validate-repo.ps1`
  (hence by the Development Gate CI job) as a child process with a strict exit
  code.

What was explicitly NOT done in PR6 (do not treat V1 as release ready;
the PR7 ownership foundation below closes only the install-manifest part):

- No byte-for-byte cross-machine reproducibility claim and no code signing or
  third-party attestation. Only content integrity and provenance of the built
  artifact are proven.
- No install manifest, no safe uninstall, no upgrade/rollback drill, and no
  `router-lifecycle.ps1` client (Router Host start/stop/status) in this slice.
- No Router Host release packaging (`build-router-host-release.ps1`) and no
  operator-facing release entry gate that requires an embedded host release.
- The packaged `uninstall_entry` is intentionally empty until an uninstall entry
  actually ships.

Consequence for the release gates below: the opt-in beta and general release
gates still require the install/uninstall/rollback drill, the release matrix on
supported Windows versions and the published known-limitations set.

### LR-15 status — PR7 install ownership foundation

`installer/scripts/router-install-ownership.psm1` installs a verified PR6 package
only into a new isolated artifact directory, records a schema-v1 install
ownership manifest and produces an exact, read-only removal plan against the
trusted package and installation receipt. It never adopts existing files or
manages real Codex user configuration. Modified/missing owned files, forged
ledgers, unsafe Windows paths and reparse points fail closed. Unowned normal
files are preserved; no recursive deletion or uninstall executor is provided.

`tests/validate-router-install-ownership.ps1` exercises isolated temporary
directories, actual Windows junctions / Linux links, PR6 provenance and failure
boundaries. It is wired into the existing canonical repository gate. See
[Install Ownership Manifest v1](ROUTER_INSTALL_OWNERSHIP.md) for ownership,
versioning, trust limits and code rollback. Actual Windows CI results remain
required; local results do not establish CI success.

Still outstanding: complete safe uninstall, upgrade/rollback drills, Router
Host release packaging, lifecycle controls and Windows release evidence. PR7
does not authorize or implement any of those features and does not declare V1
release ready.

### LR-15 status — PR8 safe uninstall execution

PR8 extends the PR7 ownership module with an opt-in `Uninstall-RouterOwnedPackage`
executor. Default invocation and WhatIf remain read-only. Execution requires a
trusted stopped lifecycle lease, freshly verified PR6/PR7 evidence and exclusive
Windows handle identity/hash/link checks. It removes only individually verified
files, handles the ownership manifest last and preserves all unowned files and
directories. A flushed write-ahead receipt supports authenticated partial retry;
ambiguous/torn state fails closed. No force, recursive removal or process killing
is supplied.

See [Safe uninstall executor](ROUTER_SAFE_UNINSTALL.md) for the trusted lifecycle
adapter contract, schema-v1 recovery, Windows-only execution and remaining race
and journal limits. PR8 supplies no production stop/start coordinator: without
that reliable lease execution is refused. Full lifecycle integration, upgrade
rollback, Host packaging and actual Windows release evidence remain outstanding.
The known MiMo idle-timeout CI flake remains an independent risk; no assertion
or timeout relaxation is authorized by this slice.

### LR-15 status — PR9 Router Host release packaging

PR9 adds `build-router-host-release.ps1` and an independent Host component
manifest/verifier. It publishes the existing .NET 10 Host as framework-dependent
win-x64 from an explicit clean Git HEAD export, with portable/RID locked restores
in isolated source copies and no production project changes. The verifier requires
external manifest/content digests, source/version/RID identities and exact files;
the existing defaults remain Router-disabled. The canonical gate cross-publishes
the real graph and on Windows starts only the verified apphost in a cleared,
temporary child environment. Linux does not establish Windows execution evidence.

See [Router Host release packaging](ROUTER_HOST_RELEASE.md). This is a compiled
component, **not a complete V1 installation package**. A controlled composition
stage must bind PR6 and Host provenance to a combined ledger before PR7/PR8 can
manage these binaries. Direct Host-package installation/uninstall is refused;
PR6 schema and PR7/PR8 contracts are unchanged. Full product composition,
production stop/start leases, upgrade/rollback and Windows release acceptance
remain outstanding. No Provider/model/routing/UI changes are authorized here.

## Cross-slice test matrix

| Test type | First owning slice | Required thereafter |
|---|---|---|
| Static architecture invariant | LR-0 | every PR |
| Core unit/state/error | LR-1 | every runtime PR |
| Config/migration/secret/ownership | LR-2 | every state/config PR |
| Ingress/SSE/cancellation | LR-3 | every transport/protocol/provider PR |
| Resolver/capability/model identity | LR-4 | every adapter/policy PR |
| Provider contract kit/fake integration | LR-5 | every provider adapter PR |
| Protocol semantic golden set | LR-8 | every protocol/provider change |
| Redaction/health | LR-9 | every trace/provider/client change |
| Usage/cost/failover decisions | LR-10/LR-11 | every pricing/policy change |
| Direct CLI regression | LR-0 static, LR-12 behavior | every integration/release PR |
| Desktop regression | LR-0 static, LR-13 behavior | every Desktop/release PR |
| V4 regression | existing suite, LR-14 additions | every UI/release PR |
| Clean-package/load/security eval | LR-15 | every release candidate |

### LR-15 status — PR10A Windows Host startup gate

PR10A adds a native cross-process startup boundary keyed by current Windows user
and physical local NTFS runtime directory. Enabled Bootstrap acquires it before
ownership inspection/bind and retains it through runtime, drain and owner
archival. Disabled startup creates no coordination state. The existing lifecycle
state machine and schema-v1 Owner Record remain unchanged.

See [Windows Host startup gate](ROUTER_HOST_STARTUP_GATE.md) for directory pinning,
private kernel-object security, dedicated-thread mutex ownership, isolated
Windows tests and trust limits. This is restricted runtime coordination only:
no production stop controller, installation binding or PR8 stopped lease is
supplied; PR9 remains an independent component with installation forbidden.
Native concurrency acceptance still requires actual Windows Development Gate
evidence. Linux validation does not establish that evidence.

### LR-15 status — PR10B Router Host lifecycle controller

PR10B adds the operator-facing Host lifecycle controller
(`installer/scripts/router-lifecycle.ps1`): strictly read-only Status, verified
Start and authenticated graceful Stop. Status prefers UNKNOWN over any
unprovable state and never reports STOPPED from a missing owner, a foreign
identity or an unproven exit. Start spawns only a PR9 verified release and
reports success only after the durable READY of the exact process it started.
Stop addresses the Host through the Host's own host-local, single-shot,
current-user-only control endpoint, then proves completion by the real process
exit, the durable STOPPED state and the archived owner record. No action kills a
process and none writes user configuration, secrets or Provider state.

See [Router Host lifecycle controller](ROUTER_HOST_LIFECYCLE.md) for exit codes,
status semantics, the control-channel construction and the deliberately BLOCKED
items. PR8 still receives no stopped lease: the
`InstallationId ↔ InstallRoot ↔ verified Host binary ↔ RuntimeDirectory ↔ process
identity` binding does not exist, so `acquireStopped` keeps failing closed and
uninstall authority is unchanged. PR6/PR7/PR9 contracts are untouched. Native
acceptance requires actual Windows Development Gate evidence; Linux validation
establishes no Windows execution evidence.

#### PR10B FIX1 — stop/start proof semantics

Independent review found three security-semantics gaps, all closed here without
redesigning the surface. Status never converts a persisted terminal state into a
verified stop: a terminal state without an independently provable current stop
proof is `UNKNOWN` with the historical state as evidence, process presence is
decided three ways (present/absent/unverifiable) and a reused PID or an
unreadable identity is never trusted. Stop only reports completion with a
confirmed exit of the verified identity's process handle, a re-read durable
`STOPPED` state and an archive bound to **this** owner (content hash plus
PID/ticks/fingerprint, matching `RouterStateStore.QuarantineAsync`'s real
byte-copy layout); every missing proof returns non-zero and no process is killed.
Start reports success only for a complete managed READY: verified release,
matching spawned identity, durable READY for that process, a control endpoint
that matches the owner and config generation, current-user-only access control
and a **live pipe instance** — a stale JSON file is not a capability. The
capability file is now created with its private descriptor at creation and
published by atomic rename, so no window exists in which the token is readable by
another principal; a Windows Host that cannot publish and verify it stops through
the existing cleanup path with its own exit code instead of serving as an
unmanaged READY router. PR10A's startup mutex, ACL and directory protections are
unchanged.

#### PR10B FIX2 — exit-evidence and capability-credential discipline

Two independent review findings closed with no redesign. Stop no longer treats a
generic `InvalidOperationException` (or any non-documented failure) as proof of
process exit: only `WaitForExit` returning true on the identity-verified handle
(`wait_for_exit_signalled`) or the documented "not running" failure
(`process_id_absent`) count as an exit, everything else is `running` or
`unverifiable`, and a still-present verified identity after a confirmed exit is
`stop_incomplete_identity_contradiction`. Capability validation is now identity
based rather than rights based: the endpoint descriptor must be protected and
every allow-grant must belong to the current user (or the local SYSTEM account),
so a read-only grant to `Users`, `Authenticated Users`, `Everyone` or any other
identity is refused as a credential leak instead of being accepted because broad
write happened to be absent. PR10A protections, PR8 fail-closed lease semantics
and every PR6/PR7/PR9 contract are unchanged.

## Release gates

### Architecture gate (LR-0)

- All three architecture documents and required sections exist.
- Responses is canonical; loopback-only/default port/security boundaries are explicit.
- Direct Mode/default-disabled/cross-model-OFF statements are explicit.
- Secret references only; no runtime state or production code.
- Static architecture validator and canonical repository validator pass.

### Runtime alpha gate

- LR-1 through LR-5 plus at least one provider adapter and LR-8 pass fake-only tests.
- No client integration/default enablement.
- Security/redaction review has no critical finding.

### Opt-in beta gate

- LR-9/LR-10/LR-11 and selected client integration pass exact rollback/Direct regression.
- User explicitly opts in; Router disabled default remains.
- Provider live/paid validation, if desired, is a separate explicitly confirmed action and its result is not inferred from fake tests.

### General release gate

- LR-15 matrix and actual Development Gate CI succeed.
- Migration and rollback drills succeed on supported Windows versions.
- No open critical/high security issue; limitations, price provenance, and unsupported capabilities documented.
- Direct Mode remains supported and default.

## Architecture Definition of Ready

LR-0 is Ready when the real repository is clean, current `main` is fast-forwarded, the architecture branch exists, and existing Direct/Desktop/V4/provider/config/test contracts have been inspected without reading secrets.

## Architecture Definition of Done

LR-0 is Done when the three documents give every component a responsibility/input/output/dependency/test owner, the contract document fixes entities/schemas/IDs/versions/APIs/adapters/states/errors/policies/security/state/migration/rollback, every build slice has all required fields, static and repository validations pass, the diff contains no production implementation, and the work remains unmerged and reviewable from a pushed feature branch.

Passing LR-0 means **architecture implementation-ready**, not that Local Router Runtime exists or has served a request.
