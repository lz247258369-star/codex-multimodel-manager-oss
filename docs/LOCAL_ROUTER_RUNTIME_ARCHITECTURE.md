# Local Router Runtime Architecture

Status: **Level 3 implementation-ready architecture; runtime not implemented**

Architecture schema: `local-router-architecture/v1`

Decision date: 2026-08-27

## Mission

Add an optional, local-only routing runtime beside Codex Multi-Model Manager's stable Direct Mode. The runtime will accept OpenAI Responses semantics from Codex CLI, Codex Desktop, and future clients, resolve an explicit route, adapt protocol/provider details, and return a normalized response without exposing upstream credentials to clients.

This document reserves boundaries and build order. It does not authorize an HTTP server, provider request, Codex user-config mutation, Desktop-route change, V4 UI change, dependency installation, or paid inference.

## Why Router Mode

Direct Mode is reliable when a provider already supports Responses semantics. Router Mode creates a future home for protocol adaptation, route health, usage/cost visibility, and policy-controlled endpoint failover without forcing those concerns into the existing launch scripts. It is an additional execution path, not a replacement model universe.

## Existing Direct Mode

The current production flow remains:

```text
Codex -> Manager -> Provider -> Model API
```

Its concrete compatibility anchors are:

- CLI: `installer/scripts/launch-controller-model.ps1` selects `chatgpt`, `modelstudio`, `openrouter`, or `mimo`, then launches Codex with the existing provider/model contract.
- Desktop: `installer/scripts/desktop-chat-route.ps1`, `installer/scripts/desktop-chat-provider.ps1`, and the generic Desktop route preserve their current backup/restore behavior.
- Providers: existing IDs such as `mm_openai_api`, `mm_modelstudio`, `mm_openrouter`, and `mm_mimo` remain canonical Manager provider identities.
- Protocol: active Codex custom providers use Responses API semantics. Active `wire_api = "chat"` is forbidden.
- State: Manager-owned user state remains below `~/.codex/multimodel-manager/`; repository defaults contain no runtime state or secrets.
- Pricing: `installer/model-catalog.json` schema v3 remains the V4 catalog source. Router pricing will consume a versioned projection rather than fork this catalog.

No production Direct Mode file is changed by this architecture slice.

## Target Architecture

```text
                          ModeSelector (future integration point)
                         /                                      \
              Direct Mode [DEFAULT]                     Router Mode [DISABLED]
                       |                                         |
       existing launch-controller-model.ps1                Client adapters
       existing Desktop provider route                  CLI / Desktop / future
                       |                                         |
                    Provider                          127.0.0.1:47821
                       |                                         |
                   Model API                              Client Ingress
                                                                  |
                                                             Router Core
                    +------------------+---------------------------+------------------+
                    |                  |                           |                  |
              Route Resolver   Protocol Adapter Registry  Provider Adapter Registry  Trace
                    |                  |                           |                  |
              Model Mapping      canonical Responses        Secret Resolver       Usage/Cost
                    |                  |                           |
                    +------------------+---------------------------+
                                                                  |
                                                            Model Provider
```

The future `ModeSelector` has exactly two explicit values: `direct` and `router`. Repository and user defaults are `direct`; `local_router.enabled` is `false`. Selecting Router Mode must never rewrite Direct Mode definitions. A client-specific integration may point a new, separately owned Codex profile at `http://127.0.0.1:47821/v1`, but only after an explicit, backup-preserving action in a later PR.

## Component boundaries

Every component below uses `contracts/v1`, accepts only validated typed input, returns a typed result or normalized error, carries `request_id` and `trace_id` when request-scoped, and has a single owning PR slice. Components cannot read project files or Codex `auth.json`.

| # | Component | Responsibility | Input -> output | State and dependency boundary | Implementation and test owner |
|---:|---|---|---|---|---|
| 1 | Router Core | Orchestrate one request without embedding provider/protocol logic | `CanonicalRequest + RequestContext -> CanonicalResponse/EventStream` | Depends on resolver, registries, policies, trace; request-local checkpoint only | LR-1; unit orchestration and contract golden set |
| 2 | Client Ingress | Bind loopback, validate HTTP/auth/body limits, create context | HTTP Responses request -> canonical request or normalized error | No route/provider selection; owns connection cancellation | LR-3; ingress contract/integration tests |
| 3 | Route Resolver | Select one enabled route from an immutable snapshot | canonical request + client/model -> `ResolvedRoute` | Pure deterministic selection; health is an input, not mutable here | LR-4; table/golden tests |
| 4 | Provider Adapter Registry | Resolve a provider ID/version to one adapter | `provider_id + adapter_version -> ProviderAdapter` | Reuses Manager provider identities; no implicit fallback | LR-4; registry contract tests |
| 5 | Protocol Adapter Registry | Resolve canonical/upstream protocol pair | `protocol_id + version -> ProtocolAdapter` | V1 only passes Responses-compatible upstreams; converters deferred | LR-8; conformance fixtures |
| 6 | Model Mapping Registry | Map client model aliases to explicit upstream model IDs | client/model/route -> `ModelRoute` | Versioned snapshot; no model identity guessing | LR-4; ambiguity and exact-match tests |
| 7 | Secret Resolver Interface | Resolve a `secret_ref` just-in-time | reference + provider scope -> ephemeral secret handle | V1 environment references only; value never enters config/log/state | LR-2; fake resolver/redaction tests |
| 8 | Router Configuration | Merge defaults and user config, validate schema | repository defaults + user config -> immutable config | No secrets; atomic migration/backup boundary | LR-2; schema/migration tests |
| 9 | Router Lifecycle | Own process states and transitions | start/stop/fault signal -> lifecycle state | Owns PID/state file and graceful drain | LR-1/LR-2; transition/crash recovery tests |
| 10 | Health Check | Report liveness/readiness without paid inference | local component state -> health view | Startup checks are local only; upstream active probes explicit/deferred | LR-9; degraded-state fixtures |
| 11 | Request Trace | Correlate safe events within one request | trace events -> bounded trace record | Metadata only; no prompt/tool payload/auth headers | LR-9; redaction and correlation tests |
| 12 | Request Log | Emit structured operational records | normalized event -> JSONL/log sink | Default metadata-only; rotation and retention policy | LR-9; forbidden-field tests |
| 13 | Usage Metering | Normalize provider usage when available | upstream usage -> `UsageRecord` | Missing fields remain null/estimated=false | LR-10; provider fixture tests |
| 14 | Cost Metering | Estimate cost from versioned prices | usage + pricing snapshot -> `CostEstimate` | Informational, never billing truth | LR-10; decimal/unknown-price tests |
| 15 | Retry Policy | Decide whether same-route replay is safe | error/attempt/stream state -> retry decision | No retry after observable output; bounded and jittered | LR-11; retry matrix tests |
| 16 | Timeout Policy | Apply connect, first-byte, idle, total deadlines | route policy + request -> cancellation deadlines | Deadlines only decrease downstream | LR-11; deterministic-clock tests |
| 17 | Failover Policy | Select explicitly allowed alternate route | failure + policy + candidates -> decision | Cross-model fallback OFF; no silent semantic change | LR-11; forbidden/default tests |
| 18 | Circuit Breaker boundary | Isolate unhealthy endpoint attempts | outcome stream -> endpoint admission decision | Per endpoint/provider/model key; starts disabled in V1 | LR-11; state-machine tests |
| 19 | Streaming / SSE handling | Preserve ordered Responses events and backpressure | upstream events -> downstream SSE | First emitted byte closes retry boundary | LR-3/LR-8; fragmented SSE/golden tests |
| 20 | Tool-call handling | Preserve tool call IDs/arguments/results | canonical tool items <-> upstream items | Router never executes tools; unsupported mapping fails closed | LR-3/LR-8; round-trip fixtures |
| 21 | Error normalization | Map internal/upstream failures to stable envelope | arbitrary failure -> `RouterError` | Retain safe upstream status/code; redact details | LR-1/LR-5; error matrix |
| 22 | Cancellation | Propagate client abort/deadline/shutdown | cancellation signal -> upstream abort + final state | Idempotent; never converts cancel to retry | LR-3/LR-5; abort/race tests |
| 23 | Request ID / Trace ID | Validate or generate correlation IDs | optional safe header -> canonical IDs | UUIDv7 format; never trust arbitrary header content | LR-1; uniqueness/validation tests |
| 24 | Router state | Persist lifecycle/config generation, not request content | state checkpoint -> atomic state file | User-level runtime directory only; recover stale state | LR-2; corruption/atomicity tests |
| 25 | Migration / rollback | Upgrade config/state safely and reversibly | version N snapshot -> N+1 + backup receipt | Never edits unrelated Manager/Codex config | LR-2; N-1 fixture/idempotency tests |
| 26 | Feature flag | Keep Router unavailable unless explicitly enabled | defaults + user opt-in -> mode eligibility | `local_router.enabled=false`; Direct Mode default | LR-0/LR-2; default-deny static tests |
| 27 | Direct Mode compatibility boundary | Prevent Router work from changing production direct launch | integration request -> explicit separate path | Existing scripts are protected regression fixtures | Every slice; Direct Mode regression suite |
| 28 | Codex CLI adapter | Describe a future Router-owned Codex profile/config projection | router config -> proposed client config | Separate managed block/profile; backup + explicit enable later | LR-12; config golden tests; not implemented now |
| 29 | Codex Desktop adapter | Describe future new-session routing through Router | Router readiness + explicit action -> proposed Desktop route | Must preserve current Desktop backup/restore and restart rule | LR-13; Desktop rollback tests; not implemented now |
| 30 | Future client adapter boundary | Admit clients without core-specific branches | `ClientDescriptor + Responses request` -> ingress context | Capability/auth/version negotiation only | Post-LR-14; SDK/contract tests |

### Level 3 component card contract

Before a component's implementation PR may be marked Ready, its design card must fill every field below. The table above supplies ownership and unique boundaries; `LOCAL_ROUTER_RUNTIME_CONTRACTS.md` supplies shared schema and call contracts; `LOCAL_ROUTER_RUNTIME_ROADMAP.md` supplies build/PR/release data. Together they are normative for all 30 components.

| Required field | Normative source |
|---|---|
| Responsibility, input, output, upstream/downstream dependency | component table and data/request flows in this document |
| Core entity, schema, ID, version, calling contract | Contracts: entities, schemas, IDs/versions, interfaces |
| State machine and checkpoint/state | Contracts: lifecycle/health/request machines and persistence |
| Provider and Protocol Adapter boundaries | Contracts: adapter interfaces and capability matrix |
| Error, retry, timeout, idempotency, cancellation | Contracts: execution policies |
| Trace/observability, permission, secret | Contracts: observability, local auth, secret references |
| Migration, feature flag, rollback | configuration and migration sections in both documents |
| Unit, contract, integration, regression, golden fixture, eval | Roadmap slice plus test strategy below |
| Release gate, build order, PR boundary, out of scope | Roadmap |
| Definition of Ready and Definition of Done | Roadmap per slice |

An implementation slice is **NOT READY** if any card field is blank, uses a secret value, depends on an unspecified adapter capability, or alters a protected Direct Mode file without a separately approved integration slice.

## Data flow

1. Configuration loader reads checked-in defaults and optional user config, validates `schema_version`, and produces immutable generation `config_generation`.
2. Registries build an immutable snapshot of clients, protocols, providers, model mappings, routes, policies, health, and pricing projections.
3. Ingress authenticates the local client and normalizes a Responses request; request bodies remain in memory only.
4. Route Resolver selects exactly one route using explicit IDs, enabled state, priority/weight, health, and failover policy.
5. Secret Resolver validates the selected route's environment-variable reference and returns an ephemeral handle to the provider adapter.
6. Protocol Adapter produces the upstream representation. In V1 this is a Responses-compatible pass-through/normalization contract, not a Chat conversion.
7. Provider Adapter sends the upstream request, streams events, normalizes usage/errors, and observes cancellation/timeouts.
8. Router emits the response while Trace/Usage/Cost receive redacted metadata events.
9. Final request state is checkpointed only as safe operational metadata; prompts, tool payloads, images, secrets, and Authorization headers are excluded.

## Request flow

```text
HTTP receive
  -> validate host/method/path/content length/client token
  -> assign request_id + trace_id
  -> parse canonical Responses request
  -> snapshot config/registries
  -> resolve route and capabilities
  -> resolve secret reference
  -> apply deadlines/retry admission
  -> call protocol adapter
  -> call provider adapter
  -> stream or buffer canonical response
  -> collect usage and estimate cost
  -> emit redacted completion record
```

Any validation failure stops before secret resolution. Any missing secret stops before network I/O. Once downstream SSE bytes are observable, no transparent retry or fallback is allowed. Client disconnect, timeout, or shutdown propagates cancellation to the upstream transport and ends as `CANCELLED` unless an earlier terminal failure won the race.

## Protocol flow

Canonical ingress is **OpenAI Responses API semantics**:

- `POST /v1/responses`
- `GET /health`
- `GET /v1/router/status`

`POST /v1/responses` is authenticated. `GET /health` is unauthenticated but returns only process liveness/readiness and a schema version. `GET /v1/router/status` is authenticated and returns a redacted status snapshot.

### V1 capability line

| Concern | V1 contract | Deferred boundary |
|---|---|---|
| Text and instructions | Responses input/items and text output | provider-specific extensions |
| Streaming/SSE | Ordered Responses events, keepalive comments, backpressure, disconnect cancellation | resume/replay after emitted bytes |
| Reasoning content | Preserve supported canonical reasoning summary/opaque items; never log content | lossy conversion to protocols without equivalent semantics |
| Tool calls/results | Preserve call IDs, names, JSON arguments, outputs; router never executes tools | provider-specific tool grammars needing lossy conversion |
| Images/multimodal | Detect and fail `unsupported_capability` unless selected adapter explicitly declares exact support | image/audio/video mapping and uploads |
| Usage | Normalize input/output/cached tokens when supplied; unknown is null | provider billing reconciliation |
| Errors | Stable normalized envelope and safe upstream metadata | provider-specific diagnostic plug-ins |
| Cancellation | Client disconnect, total deadline, shutdown drain | background Responses and explicit cancel endpoint |
| Protocol adapters | OpenAI Responses compatible upstream only | Anthropic Messages, Chat-compatible/provider-specific conversion |

The canonical protocol never becomes Chat Completions. Future adapters may translate canonical Responses requests to Anthropic Messages or provider-specific OpenAI-compatible APIs, but only when their capability matrix proves streaming, reasoning, tools, errors, cancellation, and usage behavior. Unsupported semantics fail closed; they are never silently dropped.

## Provider reuse and adapter boundary

Router provider definitions reference existing Manager identities and model metadata. They do not create alternate provider/model identities.

| Manager identity | Router V1 disposition | Secret reference | Owner slice | Notes |
|---|---|---|---|---|
| `chatgpt` / OpenAI account | `DIRECT_ONLY` initially | none | Direct Mode only | Router must not read `auth.json` or proxy ChatGPT account credentials. Existing official Direct Mode remains the path. |
| `mm_openai_api` | planned Responses adapter | `CODEX_OPENAI_API_KEY` | LR-7A | Separate from ChatGPT account login. |
| `mm_modelstudio` | planned Responses adapter | `CODEX_DASHSCOPE_API_KEY` | LR-7 | Reuses configured base URL by safe reference/projection. |
| `mm_openrouter` | planned Responses adapter | `OPENROUTER_API_KEY` | LR-6 | Gateway remains explicit in route metadata. |
| `mm_mimo` | planned Responses adapter | `MIMO_API_KEY` | LR-7B | Supports configured endpoint reference. |

Reserved adapter IDs include `deepseek_direct`, `qwen_direct`, `zai`, `anthropic`, `minimax`, `siliconflow`, `modelscope`, `nvidia`, and vendor-namespaced future IDs. Reservation is not approval, configuration, health, or protocol compatibility. Each future adapter must bind to an existing or explicitly approved Provider registry entry and pass Responses/protocol contract tests.

## Security boundary

### Network

- V1 binds only IPv4 `127.0.0.1`; configured `0.0.0.0`, non-loopback addresses, wildcard binds, and remote forwarding are rejected.
- Default port is `47821`. It is intentionally a configurable, project-specific high port and is not copied from another router. Availability is not assumed.
- Startup performs a loopback bind probe and single-instance ownership check. A conflict returns `ROUTER_PORT_IN_USE` and exits; no silent random-port selection occurs.
- Host validation accepts only the configured numeric loopback host/port. Redirects and proxy-forwarded client identity are ignored/rejected in V1.
- Shutdown stops admission, drains bounded in-flight requests, cancels after the grace deadline, atomically records terminal state, and releases the socket.

### Local auth and browser/CSRF boundary

- `POST /v1/responses` and `/v1/router/status` require a local bearer capability referenced by `CODEX_LOCAL_ROUTER_TOKEN`; no token value belongs in repository/user JSON/logs.
- `/health` exposes no routes, providers, models, paths, errors, or secrets.
- Browser `Origin` requests are denied by default; no CORS headers are emitted. State-changing browser GETs do not exist.
- Request size, header size, connection count, and idle time have configured limits.
- Loopback is a transport boundary, not an authorization substitute.

### Process ownership

Runtime ownership record is `~/.codex/multimodel-manager/local-router/runtime/router.pid.json` and contains schema version, PID, process start fingerprint, host, port, owner user SID hash, config generation, and start time—never command-line secrets. Startup validates PID plus fingerprint. A dead/mismatched owner is stale, archived to a recovery record, and replaced atomically. A live matching owner causes `ROUTER_ALREADY_RUNNING`. No process is killed automatically.

## Secret boundary

```text
Client -> local bearer reference -> Router -> upstream secret_ref -> Secret Resolver -> Provider
```

Clients never receive or configure an upstream key. Provider adapters accept only an opaque `SecretHandle`, never raw configuration values. V1 resolver supports environment-variable references at Process/User scope with an explicit allowlist. Example references are names only: `OPENROUTER_API_KEY`, `CODEX_DASHSCOPE_API_KEY`, and `MIMO_API_KEY`.

Future resolver types may include Windows Credential Manager, OS Keychain, encrypted local vault, or an external secret provider. This architecture does not implement a store.

Secret rules:

- `secret_ref` has resolver kind, reference name, allowed provider IDs, scope, and version; it never contains a value.
- Resolution occurs after route selection and before the upstream call, and the value remains in the smallest possible memory scope.
- Logs, traces, errors, dumps, state, config backups, and health output must redact Authorization, cookies, query credentials, all resolved values, and secret-like fields.
- Rotation is observed on the next request or explicit resolver cache expiry; V1 defaults to no value cache.
- Missing/empty/not-allowed references yield `secret_missing`/`secret_scope_violation` before network I/O.

## State machines

### Router lifecycle

```text
STOPPED -> STARTING -> READY -> STOPPING -> STOPPED
                      |  ^
                      v  |
                   DEGRADED
STARTING -> FAILED
READY/DEGRADED/STOPPING -> FAILED
FAILED -> STOPPED (explicit cleanup/restart only)
```

Forbidden: `STOPPED -> READY`, `FAILED -> READY`, `STOPPING -> STARTING`, and any transition that skips ownership/config validation. `DEGRADED` may serve only when the selected route remains healthy and policy permits it.

### Route health

```text
UNKNOWN -> HEALTHY | DEGRADED | UNHEALTHY | DISABLED
HEALTHY <-> DEGRADED -> UNHEALTHY
UNHEALTHY -> DEGRADED | HEALTHY
any non-DISABLED -> DISABLED (configuration)
DISABLED -> UNKNOWN (explicit re-enable)
```

Forbidden: `DISABLED -> HEALTHY` without re-enable and evaluation; health alone cannot enable a route. V1 startup health is passive/local. Paid inference is never a health probe.

### Request

```text
RECEIVED -> ROUTED -> UPSTREAM_PENDING -> STREAMING -> COMPLETED
    |          |              |              |
    +----------+--------------+--------------+-> FAILED
    +----------+--------------+--------------+-> CANCELLED
UPSTREAM_PENDING -> COMPLETED (non-streaming)
```

Terminal states are immutable. `STREAMING -> ROUTED`, terminal-to-anything, `RECEIVED -> STREAMING`, and retry after downstream output are forbidden. Retry attempts remain within `UPSTREAM_PENDING`; fallback creates an auditable attempt under the same request, only when policy permits.

## Router state and checkpoints

The Router persists only control-plane state: lifecycle, config generation/hash, migration receipt, PID ownership, sanitized route-health aggregates, breaker state when enabled, and bounded idempotency metadata/results when policy allows. Prompt/input/output/tool/image content is not a checkpoint. Request completion logs are observability records, not recoverable conversations.

Configuration and state writes use same-directory temporary files, flush, atomic replace, restrictive user ACLs, and a verified backup receipt. A corrupt file is never overwritten in place: startup quarantines it by timestamp/hash, reports `config_corrupt` or `state_corrupt`, and either uses repository defaults only when that is safe (Router remains disabled) or fails closed.

## Observability and redaction

Default operational records may include:

`request_id`, `trace_id`, `route_id`, `provider_id`, `model_id`, `latency_ms`, `ttft_ms`, `input_tokens`, `output_tokens`, `cached_tokens`, `cost_estimate`, `status_code`, `normalized_error`, `retry_count`, and `fallback_count`.

Default records must not include prompt/input/output text, reasoning content, tool arguments/results, image bytes/URLs, API keys, Authorization/Cookie headers, raw query strings, user-project secrets, environment dumps, or `auth.json`. Redaction runs before serialization and again at sink boundaries. Unknown fields are deny-by-default. A redaction failure drops the record and emits a content-free counter.

## Pricing and cost compatibility

Router pricing projects the existing V4 fields (`price_input`, `price_output`, `price_currency`, `price_source`, `price_updated_at`, and `price_basis`) into versioned `ModelPricing` records. It adds cached-input price, unit, effective time, source version, and confidence/verification state without mutating `installer/model-catalog.json` in Router runtime slices.

`ProviderPricing` can override a model price for a specific provider/endpoint and effective interval. `UsageRecord` preserves provider-reported counts and provenance. `CostEstimate` uses decimal arithmetic and the pricing snapshot active when routing began. Missing/unverified price yields an explicit unknown/partial estimate; it never becomes zero. Router estimates are informational and do not guarantee current provider pricing or billing.

## Failure model

- Validation/auth/capability/secret errors fail before upstream I/O.
- Same-provider retry is limited to transient connection, timeout-before-output, 408/429, and selected 5xx errors when idempotency permits.
- Same-model alternate endpoint is OFF unless an explicit route policy enables named endpoints.
- Same-model alternate provider is OFF unless explicitly enabled and model identity/capability equivalence is approved.
- Cross-model fallback is **OFF by default** and requires an explicit ordered allowlist plus a client-visible trace annotation because behavior may change.
- No failover may cross secret scope, protocol capability, data residency, or permission boundaries.
- Circuit breaker is a boundary only in early slices and remains disabled until LR-11.
- Streaming failure after first output is terminal; the Router emits a safe error event/connection close per Responses semantics and does not replay.

## Configuration ownership

| Class | Canonical planned location | Git policy |
|---|---|---|
| Repository defaults | `local-router/config/router.defaults.json` | tracked, schema-validated, no secrets, Router disabled |
| User config | `~/.codex/multimodel-manager/local-router/router.config.json` | never tracked; references only |
| Runtime state/PID | `~/.codex/multimodel-manager/local-router/runtime/` | never tracked |
| Secrets | V1 environment-variable resolver; future OS/external stores | values never written by Router config |
| Logs | `~/.codex/multimodel-manager/local-router/logs/` | never tracked; restrictive ACL/rotation |
| Backups | `~/.codex/backups/local-router/<timestamp-id>/` | never tracked; receipt and exact rollback source |

Precedence is repository defaults < user config < explicit process startup options. Security invariants (loopback-only, no secret values, cross-model fallback default OFF) cannot be weakened by ordinary route entries. All files carry `schema_version`; writes use optimistic `version`, atomic replace, and idempotent migration IDs.

## Compatibility

The compatibility boundary is fixed:

```text
ModeSelector
├── Direct Mode [default]
│   ├── existing launch-controller-model.ps1 / Codex CLI
│   └── existing Desktop route
└── Router Mode [optional, default disabled]
    └── Local Router Runtime
```

Router implementation must be additive. It must not change production behavior in `launch-controller-model.ps1`, `desktop-chat-provider.ps1`, `desktop-chat-route.ps1`, any future generic Desktop provider script, or V4 UI files. Integration PRs may add separate adapters only after Router readiness, backups, explicit enablement, and Direct Mode regression evidence.

## Migration

Configuration migrations are forward, version-by-version functions with deterministic fixture tests. Before mutation they validate source schema, write a content-hash backup, generate a migration receipt, apply to a temporary sibling, validate the result, and atomically replace. Re-running the same migration is a no-op. Unknown newer schema fails closed. Repository defaults never migrate user files merely because the code was updated; migration occurs only on explicit Router start/config command in a later PR.

Model/provider migration cannot infer identity. Provider/model aliases remain stable until an explicitly confirmed mapping exists. This inherits the repository's stealth-model rules.

## Rollback

Rollback stops Router admission, restores the exact prior user config/state from a verified receipt, leaves secrets untouched, and returns `mode=direct` with `local_router.enabled=false`. If restore verification fails, Router stays disabled and reports the backup path; it does not edit Direct Mode or Codex Desktop config. Runtime deletion is not automatic. A later uninstall may archive Router runtime files only after explicit confirmation.

## Test strategy and release gate

- Unit: pure resolver/policy/state/ID/pricing/redaction functions with fake clock and fake secrets.
- Contract: JSON schema and adapter conformance against versioned canonical fixtures.
- Integration: in-process fake upstream only; no external provider or paid request.
- Regression: protected Direct Mode scripts and existing validations remain byte/behavior compatible unless an explicitly approved integration slice says otherwise.
- Golden set: Responses non-stream/stream, reasoning, tools/results, usage, errors, cancellation, unsupported multimodal, retry boundary, corrupt config, stale PID, and redaction fixtures.
- Eval: deterministic semantic-preservation checks; live provider eval is a separate, explicit, potentially paid post-implementation gate.
- Release gate: repository validation, Local Router architecture/contract validation, slice tests, secret scan, Direct Mode regression, clean diff review, and actual CI success before merge. Local PASS is not CI PASS.

## Production execution composition remediation

`Router.Execution` is the production composition boundary. When Router Mode is
enabled, `RouterHostBootstrap` builds one immutable
`RouterRegistrySnapshot`, one `ProviderAdapterRegistry` (exactly
`mm_openrouter`, `mm_modelstudio`, `mm_openai_api`, `mm_mimo`), one
`ProtocolAdapterRegistry` (Responses only), one `HttpUpstreamTransport`, and a
`RouterExecutionResponsesService` implementing `IResponsesService`.
`FakeResponsesService` is a test-only injectable override and is never
constructed in Host production source.

Each production result carries versioned `ResponsesExecutionMetadata`
(provider/route/model-route/catalog-model/upstream-model identity) derived from
`ResolvedRoute` plus the executed attempts and is deliberately two-phase.
`ExecutionStartedAt` is the first upstream attempt start. As soon as a route is
resolved and a provider attempt starts, every identity field is authoritative
and is attached to the result returned to the caller — including streamed
results, before any event is enumerated, with `CompletedAt == null` because
terminal time is still unknown. Already-terminal (non-stream and failure)
results attach the same identity with the true terminal `CompletedAt`; the
terminal-aware stream wrapper later emits the same identity with the real
terminal timestamp exactly once at stream completion, terminal provider
failure, cancellation, or mapping failure. LR-10R (PR #85 rebased onto this
main) must consume this metadata for metering attribution instead of guessing
routes from configuration order.

Production endpoint composition is a four-provider URI contract. Each endpoint
resolves from the repository-approved Manager base URL
(`provider-config:mm_*.base_url` references) with no test override, and each
concrete provider adapter composes its own request path against that value.
The closed contract is exact: `https://api.openai.com/v1/responses`,
`https://dashscope.aliyuncs.com/compatible-mode/v1/responses`,
`https://openrouter.ai/api/v1/responses`, and
`https://api.xiaomimimo.com/v1/responses`. The contract tests construct
`UpstreamRequest.FullUri` directly and never send a request.

Route resolution consumes the current dynamic passive-health projection on
every request (initial and failover resolution): `PassiveHealthTracker`
records real outcomes under the same LR-9 policy and re-keys them by configured
route id (`RouteHealthProjection`), and the execution service converts that
projection to the LR-4 `RouteHealthSnapshot` input. No second health algorithm
exists. A route that the tracker marks UNHEALTHY is no longer selectable.

Streamed executions are attempts, not outcomes: the provider harness only
establishes that a stream was returned; the result returned to the caller
carries the full authoritative identity with `CompletedAt == null`, and the
outcome sink is not called. A terminal-aware stream wrapper finalizes success,
failure, cancellation, and protocol-mapping failure exactly once at the true
terminal boundary, feeding passive health and the circuit breaker and emitting
terminal metadata with the same identity and the real `CompletedAt`. Because
the wrapper runs outside the attempt/retry/failover loop, no retry or failover
ever occurs after a stream has been returned, and client cancellation is never
recorded as a provider failure. Consumers always observe the protocol-adapter
mapped canonical event from the terminal-aware stream; the raw inner provider
event never crosses the consumer boundary.

Known explicit gaps:

- Router config schema v1 declares policy identifiers only; policy bodies are
  not yet configurable, so every route executes with the single deterministic
  safe policy set in `RouterExecutionPolicySet` (retry bounded, timeout
  bounded, failover OFF, circuit breaker DISABLED, cross-model fallback
  hard-OFF). `POLICY_BODY_CONFIGURATION_GAP = YES`: there is no policy registry,
  policy store, or policy-body config projection that can construct retry,
  timeout, failover, or circuit-breaker bodies from a configured
  `policy_id`/`version`; SafeDefaults is the conservative production fallback
  and is never claimed to be configured policy composition.
- Retry decisions reuse `RetryPolicyEngine`; upstream `Retry-After` headers are
  not surfaced by the existing adapter contract, so bounded backoff applies
  without a server-supplied delay.
- Same-model alternate endpoint is expressed and executed at the router-route
  granularity: two routes over the same provider and same client model with
  distinct provider routes/endpoints. A failover candidate that resolves to
  the exhausted route's own endpoint is skipped rather than mislabeled as an
  alternate endpoint. Failover within one `ProviderRoute`'s endpoint set is not
  a router-route concept and is not claimed.

## Out of Scope

- Implementing or starting an HTTP server.
- Installing a runtime or dependency.
- Calling provider APIs or paid inference.
- Reading API keys, `auth.json`, or project `.env` files.
- Modifying Codex user config, Desktop routing, Direct Mode, V4 UI, or production switching.
- Chat Completions ingress or active `wire_api = "chat"`.
- Automatic cross-model fallback, tool execution, multimodal conversion, background Responses, remote listening, browser UI, secret store, or billing reconciliation.
- Copying CC Switch code, brand, port, or assumptions. Only generic public routing patterns may inform later independent design review.

## Build order

The enforced order is architecture gate -> core types/lifecycle skeleton -> config/state/security -> Responses ingress -> registries/resolver -> one fake adapter -> individual provider adapters -> protocol boundary -> health/observability -> usage/cost -> opt-in failover -> CLI integration -> Desktop integration -> hardening/release. Exact independently mergeable slices, readiness, rollback, and PR boundaries are defined in `LOCAL_ROUTER_RUNTIME_ROADMAP.md`.

This architecture is implementation-ready only when the contracts and roadmap documents pass `tests/validate-local-router-architecture.ps1`. That static result does not claim a working Router.
