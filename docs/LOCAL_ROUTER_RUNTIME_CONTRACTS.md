# Local Router Runtime Contracts

Status: **normative design contract; no runtime implementation**

Contract namespace: `codex.multimodel.local-router`

Contract version: `1.0.0-draft`

## Contract rules

1. OpenAI Responses API semantics are the only V1 canonical ingress.
2. Existing Manager provider/model identities are reused; a Router record is a route to an existing identity, not a second catalog.
3. Direct Mode is default and remains operational without any Router file, process, config, or state.
4. `local_router.enabled` defaults to `false`; cross-model fallback defaults to `OFF`.
5. Config and schemas contain secret references only. Secret values, Authorization headers, prompt content, tool payloads, and project secrets are prohibited from persistence/logging.
6. Unknown enum/schema versions and unsupported capabilities fail closed.
7. Adapter calls are cancellation-aware and use immutable request/config snapshots.

Normative words MUST, MUST NOT, SHOULD, and MAY express implementation requirements.

## IDs and versions

| Type | Format/example | Stability |
|---|---|---|
| `client_id` | `client.codex_cli`, `client.codex_desktop` | stable registry key |
| `provider_id` | existing `chatgpt`, `mm_openai_api`, `mm_modelstudio`, `mm_openrouter`, `mm_mimo` | matches Manager identity |
| `protocol_id` | `protocol.openai.responses.v1` | versioned semantic family |
| `adapter_id` | `adapter.provider.mm_openrouter.responses.v1` | immutable behavior version |
| `route_id` | `route.<lower-kebab-slug>` | user/config stable |
| `provider_route_id` | `provider-route.<lower-kebab-slug>` | config stable |
| `protocol_route_id` | `protocol-route.<lower-kebab-slug>` | config stable |
| `model_route_id` | `model-route.<lower-kebab-slug>` | config stable |
| `endpoint_id` | `endpoint.<lower-kebab-slug>` | config stable |
| `policy_id` | `policy.<lower-kebab-slug>` | config stable |
| `request_id` | `req_<UUIDv7-lowercase>` | generated per ingress request |
| `trace_id` | `trc_<UUIDv7-lowercase>` | generated or validated per trace |
| `attempt_id` | `att_<UUIDv7-lowercase>` | generated per upstream attempt |
| `response_id` | preserve safe upstream ID or `resp_<UUIDv7>` | one canonical response |
| `config_generation` | lowercase SHA-256 of normalized effective config | immutable snapshot identity |

IDs are ASCII, case-sensitive, length-limited to 128 characters, and never derived from a secret or prompt. User-provided request/trace headers are accepted only if they match the format and size; otherwise Router generates new IDs and never echoes unsafe text.

Versions have separate meanings:

- `schema_version`: integer file/schema migration version, initially `1`.
- `contract_version`: semantic adapter/API contract, initially `1.0`.
- entity `version`: positive integer used for optimistic concurrency.
- `adapter_version`: exact adapter implementation contract; registry lookup never silently upgrades a pinned major version.
- pricing `source_version`/`effective_at`: provenance, independent from schema version.

## Canonical entities

### RouterConfig

```json
{
  "schema_version": 1,
  "version": 1,
  "mode": "direct",
  "local_router": {
    "enabled": false,
    "host": "127.0.0.1",
    "port": 47821,
    "client_auth": {
      "mode": "bearer_env_ref",
      "token_ref": "CODEX_LOCAL_ROUTER_TOKEN"
    },
    "limits": {
      "max_request_bytes": 16777216,
      "max_header_bytes": 32768,
      "max_connections": 32,
      "shutdown_grace_ms": 15000
    }
  },
  "clients": [],
  "protocol_routes": [],
  "provider_routes": [],
  "model_routes": [],
  "routes": [],
  "policies": [],
  "updated_at": "2026-08-27T00:00:00Z"
}
```

Invariants: `mode=router` is invalid unless `enabled=true`; default merge yields `mode=direct` and `enabled=false`; host MUST equal `127.0.0.1`; port is `1..65535`; Router will fail on a conflict rather than silently change it. Security limits have hard implementation ceilings. No unknown field can weaken a security invariant.

### ClientDefinition

```json
{
  "client_id": "client.codex_cli",
  "adapter_id": "adapter.client.codex_cli.responses.v1",
  "enabled": true,
  "auth_scope": "responses:invoke",
  "allowed_route_ids": ["route.openrouter-default"],
  "capabilities": ["text", "streaming", "reasoning", "tools", "usage"],
  "version": 1
}
```

Client capability declarations limit access; they do not force a provider to support a feature. The effective capability set is the intersection of client, canonical ingress, protocol adapter, provider adapter, model, and route policy.

### ProtocolRoute

```json
{
  "protocol_route_id": "protocol-route.responses-pass-through",
  "ingress_protocol": "protocol.openai.responses.v1",
  "upstream_protocol": "protocol.openai.responses.v1",
  "adapter_id": "adapter.protocol.responses-compatible.v1",
  "adapter_version": "1.0",
  "capabilities": ["text", "streaming", "reasoning", "tools", "usage", "cancellation"],
  "loss_policy": "fail_closed",
  "version": 1
}
```

V1 permits only Responses-compatible upstream protocol routes. Reserved future upstream protocols include `protocol.anthropic.messages.v1` and vendor-namespaced protocols; reservation does not make them usable.

### ProviderRoute

```json
{
  "provider_route_id": "provider-route.openrouter-primary",
  "provider_id": "mm_openrouter",
  "adapter_id": "adapter.provider.mm_openrouter.responses.v1",
  "adapter_version": "1.0",
  "endpoint_ids": ["endpoint.openrouter-primary"],
  "secret_ref": {
    "resolver": "environment",
    "name": "OPENROUTER_API_KEY",
    "scope": "user_or_process",
    "allowed_provider_ids": ["mm_openrouter"],
    "version": 1
  },
  "base_url_ref": "provider-config:mm_openrouter.base_url",
  "enabled": true,
  "capabilities": ["responses", "streaming", "reasoning", "tools", "usage", "cancellation"],
  "version": 1
}
```

`base_url_ref` is a reference to validated Manager/user configuration or a repository-approved endpoint entry; routes MUST NOT interpolate environment data or request input into URLs. Redirects to a different origin are denied by default. Provider adapters receive a validated endpoint and opaque secret handle, not arbitrary config.

### ModelRoute

```json
{
  "model_route_id": "model-route.glm53-openrouter",
  "provider_id": "mm_openrouter",
  "client_model_id": "z-ai/glm-5.3",
  "model_id": "z-ai/glm-5.3",
  "upstream_model_id": "z-ai/glm-5.3",
  "aliases": [],
  "capabilities": ["text", "streaming", "reasoning", "tools", "usage"],
  "pricing_ref": "pricing.mm_openrouter.z-ai-glm-5-3",
  "identity_verification": "explicit_config",
  "enabled": true,
  "version": 1
}
```

Model mappings are provider-scoped. Equal model strings across providers do not prove equivalence. An alias/replacement cannot be inferred from metadata, including stealth model names.

### RouterRoute

```json
{
  "route_id": "route.openrouter-glm53",
  "client_ids": ["client.codex_cli"],
  "provider_route_id": "provider-route.openrouter-primary",
  "protocol_route_id": "protocol-route.responses-pass-through",
  "model_route_id": "model-route.glm53-openrouter",
  "enabled": true,
  "priority": 100,
  "weight": 100,
  "health_state": "UNKNOWN",
  "timeout_policy_id": "policy.timeout.default",
  "retry_policy_id": "policy.retry.safe-default",
  "failover_policy_id": "policy.failover.off",
  "fallback_route_ids": [],
  "created_at": "2026-08-27T00:00:00Z",
  "updated_at": "2026-08-27T00:00:00Z",
  "version": 1
}
```

Canonical route selection key is `(client_id, client_model_id, explicit route preference if allowed)`. Lowest numeric priority wins; weight is applied only among equally prioritized eligible routes using a deterministic request hash. A route is eligible only when enabled, allowed for the client, capability-compatible, and not `DISABLED`/`UNHEALTHY`. `UNKNOWN` eligibility is a policy decision that defaults to allowed only for local/passive health, never because a paid probe succeeded silently.

The fields in the task proposal are deliberately split: provider endpoints belong in `ProviderRoute`; protocol belongs in `ProtocolRoute`; model identity belongs in `ModelRoute`; client selection and policies belong in `RouterRoute`. This avoids duplicated, contradictory records.

### Endpoint

```json
{
  "endpoint_id": "endpoint.openrouter-primary",
  "base_url_ref": "provider-config:mm_openrouter.base_url",
  "priority": 100,
  "weight": 100,
  "enabled": true,
  "data_boundary": "provider-default",
  "tls_required": true,
  "version": 1
}
```

HTTP upstream endpoints require TLS except loopback fake servers in tests. Endpoint identity is included in attempt traces but omitted from unauthenticated health.

### ResolvedRoute and RequestContext

```text
ResolvedRoute {
  config_generation, route_id, client_id,
  provider_route, protocol_route, model_route, endpoint,
  effective_capabilities, timeout_policy, retry_policy, failover_policy,
  pricing_snapshot_id
}

RequestContext {
  request_id, trace_id, client_id, received_at, deadline_at,
  config_generation, idempotency_key_hash?, cancellation_token,
  auth_scope, content_logging=false
}
```

Both are immutable. `RequestContext` never includes a raw bearer token. `ResolvedRoute` includes `secret_ref`, never a secret value.

## State entities

### RouterRuntimeState

```json
{
  "schema_version": 1,
  "version": 1,
  "lifecycle": "STOPPED",
  "config_generation": "<sha256>",
  "started_at": null,
  "updated_at": "2026-08-27T00:00:00Z",
  "last_failure": null,
  "migration_receipts": []
}
```

Runtime state contains no requests or secrets. PID ownership is a separate restrictive file so lifecycle recovery can validate process identity without parsing logs.

### HealthSnapshot

```json
{
  "schema_version": 1,
  "lifecycle": "READY",
  "ready": true,
  "config_generation": "<sha256>",
  "routes": [
    {
      "route_id": "route.openrouter-glm53",
      "state": "UNKNOWN",
      "reason_code": "not_probed",
      "observed_at": "2026-08-27T00:00:00Z"
    }
  ]
}
```

Public `/health` returns only `schema_version`, `lifecycle`, and `ready`. Authenticated `/v1/router/status` may return the redacted remainder. Health reasons are enum codes, not raw exception strings.

### RequestRecord

```json
{
  "schema_version": 1,
  "request_id": "req_<uuidv7>",
  "trace_id": "trc_<uuidv7>",
  "route_id": "route.openrouter-glm53",
  "provider_id": "mm_openrouter",
  "model_id": "z-ai/glm-5.3",
  "state": "COMPLETED",
  "status_code": 200,
  "latency_ms": 1250,
  "ttft_ms": 310,
  "retry_count": 0,
  "fallback_count": 0,
  "normalized_error": null,
  "usage_record_id": "usage_<uuidv7>",
  "cost_estimate_id": "cost_<uuidv7>",
  "started_at": "2026-08-27T00:00:00Z",
  "completed_at": "2026-08-27T00:00:01.250Z"
}
```

The schema intentionally has no request/response content fields.

## Pricing entities

### ModelPricing

```json
{
  "pricing_id": "pricing.openai.gpt-5-6-sol",
  "schema_version": 1,
  "provider_id": "mm_openai_api",
  "model_id": "gpt-5.6-sol",
  "input_price": "5.0",
  "output_price": "30.0",
  "cached_input_price": null,
  "currency": "USD",
  "unit": "per_1m_tokens",
  "effective_at": "2026-08-25T00:00:00Z",
  "expires_at": null,
  "source": "OpenAI API pricing",
  "source_version": "installer/model-catalog.json:v3@2026-08-25",
  "verification_state": "SOURCE_DECLARED",
  "confidence": "medium",
  "version": 1
}
```

`verification_state` is one of `UNVERIFIED`, `SOURCE_DECLARED`, `MANUALLY_VERIFIED`, `PROVIDER_REPORTED`, `STALE`; confidence is `unknown|low|medium|high`. Monetary values are decimal strings, never binary floats. Unknown values are null, never zero.

### ProviderPricing

`ProviderPricing` has the same monetary/provenance fields plus `provider_id`, optional `endpoint_id`, `model_id`, and effective interval. It overrides `ModelPricing` only for an exact provider/model/interval match. Overlap at equal precedence is a configuration error.

### UsageRecord

```json
{
  "usage_record_id": "usage_<uuidv7>",
  "request_id": "req_<uuidv7>",
  "provider_id": "mm_openrouter",
  "model_id": "z-ai/glm-5.3",
  "input_tokens": 100,
  "output_tokens": 50,
  "cached_tokens": null,
  "reasoning_tokens": null,
  "source": "provider_response",
  "estimated": false,
  "recorded_at": "2026-08-27T00:00:01Z"
}
```

### CostEstimate

```json
{
  "cost_estimate_id": "cost_<uuidv7>",
  "usage_record_id": "usage_<uuidv7>",
  "pricing_id": "pricing.openrouter.z-ai-glm-5-3",
  "amount": null,
  "currency": "USD",
  "status": "UNKNOWN_PRICE",
  "formula_version": "cost/v1",
  "calculated_at": "2026-08-27T00:00:01Z"
}
```

Status is `COMPLETE|PARTIAL_USAGE|UNKNOWN_PRICE|STALE_PRICE|UNSUPPORTED_CURRENCY`. Estimates are observability only and MUST NOT drive routing in V1.

## API contracts

### Common transport

- Bind: `http://127.0.0.1:47821` by default; port configurable, host fixed to loopback.
- Content type: `application/json` for non-stream responses; `text/event-stream` for streaming.
- Auth: `Authorization: Bearer <local-router-capability>` for protected endpoints. The value comes from `CODEX_LOCAL_ROUTER_TOKEN` and is never logged.
- Request correlation: optional valid `X-Request-Id`/`traceparent`; Router returns safe canonical correlation headers.
- Body limits are checked before parse. Compressed request bodies are rejected in V1.
- `Idempotency-Key` is optional, length-limited, hashed immediately, and never logged raw.

### `POST /v1/responses`

Input follows the supported V1 subset of OpenAI Responses semantics. Required route-relevant fields are `model` and `input`; `stream` defaults false. Unknown standard fields may be preserved only if the selected adapter declares support; unsupported behavior-changing fields produce `unsupported_parameter`.

V1 supports text/instructions, reasoning items/summaries where representable, function tool definitions, tool calls/results, streaming, usage, normalized errors, and transport cancellation. It rejects background mode, persistent conversation storage, explicit remote file fetch, and multimodal parts unless exact capability is declared. Router never executes a tool.

Success is a canonical Responses JSON object or canonical Responses SSE sequence. Router-owned metadata is exposed only through safe headers or a namespaced extension when the client explicitly opts in; canonical response fields are not repurposed.

### `GET /health`

No auth. Response:

```json
{"schema_version":1,"lifecycle":"READY","ready":true}
```

`200` means process is ready to evaluate requests; `503` means starting, stopping, failed, or no eligible route. It performs no provider call and reveals no route/provider/model/path/detail.

### `GET /v1/router/status`

Requires local auth scope `router:status`. Returns redacted lifecycle, config generation, route health enum/reason code, in-flight count, feature flag, and supported contract versions. It never returns secret refs by default, resolved secrets, base URLs with credentials/query data, raw exceptions, request content, or project paths.

### Cancellation API

V1 cancellation is transport-scoped: client disconnect/abort, timeout deadline, or shutdown cancellation token. Explicit `POST /v1/responses/{id}/cancel` is deferred with background Responses. Cancellation is idempotent and propagates to the upstream transport. A late response after cancellation is discarded and recorded only as a safe counter.

## Adapter interfaces

Contract interfaces use language-neutral pseudotypes so their behavior is independent of implementation syntax. The planned implementation substrate is **C# + ASP.NET Core**. LR-0 does not lock an exact supported .NET LTS SDK/runtime or package version; the LR-1 ADR must decide and pin the exact SDK, runtime, and package versions after toolchain, license, Windows CI, packaging, cancellation, and SSE review.

```text
interface ClientAdapterV1 {
  descriptor(): ClientDescriptor
  parse(httpRequest, cancellation): Result<CanonicalRequest, RouterError>
  write(responseOrEvents, httpResponse, cancellation): Result<void, RouterError>
}

interface RouteResolverV1 {
  resolve(request, context, registrySnapshot): Result<ResolvedRoute, RouterError>
}

interface ProtocolAdapterV1 {
  descriptor(): AdapterDescriptor
  validateCapabilities(request, resolvedRoute): Result<CapabilityPlan, RouterError>
  encode(request, capabilityPlan): Result<UpstreamRequest, RouterError>
  decodeResponse(response): Result<CanonicalResponse, RouterError>
  decodeEvent(event): Result<CanonicalEvent, RouterError>
  normalizeError(error): RouterError
}

interface ProviderAdapterV1 {
  descriptor(): ProviderAdapterDescriptor
  send(request, endpoint, secretHandle, deadlines, cancellation):
    Result<UpstreamResponse | AsyncEventStream, ProviderFailure>
}

interface SecretResolverV1 {
  resolve(secretRef, providerId, cancellation): Result<SecretHandle, RouterError>
}

interface UsageMeterV1 {
  normalize(canonicalResponseOrEvents, attempt): Result<UsageRecord?, MeteringError>
}

interface PricingResolverV1 {
  snapshot(providerId, modelId, at): Result<PricingSnapshot?, PricingError>
  estimate(usage, snapshot): CostEstimate
}
```

Descriptors include exact contract/version, provider/protocol IDs, capabilities, maximum limits, streaming framing, tool support, reasoning handling, usage quality, cancellation behavior, and error mapping version. Registry registration rejects duplicate IDs/versions and mismatched provider IDs.

Provider adapters MUST NOT select routes, read arbitrary environment variables, execute tools, log content, retry independently, or mutate configuration. Protocol adapters MUST NOT resolve secrets or endpoints. The Router Core owns retries, attempts, and cancellation.

## Provider adapter registry

| Provider ID | Registry state at architecture gate | Canonical protocol | Secret rule |
|---|---|---|---|
| `chatgpt` | `DIRECT_ONLY` | official account path outside Router | no `auth.json` access |
| `mm_openai_api` | reserved for V1 implementation | Responses compatible | `CODEX_OPENAI_API_KEY` reference |
| `mm_modelstudio` | reserved for V1 implementation | Responses compatible endpoints only | `CODEX_DASHSCOPE_API_KEY` reference |
| `mm_openrouter` | first external adapter slice | Responses compatible | `OPENROUTER_API_KEY` reference |
| `mm_mimo` | reserved for V1 implementation | Responses compatible | `MIMO_API_KEY` reference |
| DeepSeek/Qwen direct, Z.ai, Anthropic, MiniMax, SiliconFlow, ModelScope, NVIDIA, others | placeholder descriptor only | capability/protocol proof required | provider-specific reference name, never value |

An adapter placeholder cannot be enabled, healthy, selected, or advertised as supported.

## Protocol adapter registry

V1 registry contains only `protocol.openai.responses.v1 -> protocol.openai.responses.v1`. It may normalize headers, event framing, safe errors, and documented provider quirks, but cannot downgrade to Chat semantics.

Future entries may target Anthropic Messages compatible or provider-specific OpenAI-compatible protocols. Each requires bidirectional fixtures covering streaming/SSE, reasoning, tool call IDs and arguments, tool results, multimodal rejection/mapping, usage, errors, and cancellation. A semantic gap MUST be declared as `unsupported` or `lossy`; V1 route policy permits only `fail_closed`, not silent loss.

## SecretReference contract

```text
SecretReference {
  resolver: "environment" | future resolver ID,
  name: /^[A-Z][A-Z0-9_]{2,127}$/,
  scope: "process" | "user" | "user_or_process",
  allowed_provider_ids: non-empty provider ID list,
  version: positive integer
}
```

V1 allowlists known reference names per provider. It MUST reject value-like names, inline tokens, `${...}` interpolation, file paths, `.env` paths, registry commands, and arbitrary expression syntax. Resolution order for `user_or_process` is explicit and tested; rotation invalidates any optional handle cache. Missing secret returns HTTP 503 `secret_missing` before upstream I/O. Scope mismatch returns 403 `secret_scope_violation`. Neither error includes the value.

Future secret resolvers must preserve the same handle/redaction interface and define rotation, lease expiry, process scope, ACL, audit, and missing-secret behavior. No Secret Store is part of V1.

## Lifecycle contracts

### Router lifecycle transitions

| From | Allowed to | Trigger/guard | Checkpoint |
|---|---|---|---|
| `STOPPED` | `STARTING` | explicit start, feature enabled, ownership free | write owner intent |
| `STARTING` | `READY` | config valid, loopback bound, registries valid, eligible route exists | atomic ready state |
| `STARTING` | `DEGRADED` | config valid and safe service possible with non-critical warning | atomic degraded reasons |
| `STARTING` | `FAILED` | bind/config/ownership/registry failure | redacted failure code |
| `READY` | `DEGRADED` | non-terminal component/route degradation | safe reason codes |
| `DEGRADED` | `READY` | readiness guards restored | clear reasons |
| `READY`/`DEGRADED` | `STOPPING` | explicit shutdown/process signal | stop admission, drain |
| `STOPPING` | `STOPPED` | drained/cancelled and socket released | terminal state/remove live ownership |
| non-terminal | `FAILED` | unrecoverable invariant/process fault | terminal failure receipt |
| `FAILED` | `STOPPED` | explicit recovery validates no live owner | recovery receipt |

Every other transition is forbidden.

### Route health transitions

Allowed states: `UNKNOWN`, `HEALTHY`, `DEGRADED`, `UNHEALTHY`, `DISABLED`. Configuration is the only source of `DISABLED`; re-enable moves to `UNKNOWN`. Passive outcomes may move among other states using a versioned threshold policy. A single request MUST NOT directly flip to healthy after a long unhealthy interval without the configured recovery threshold. Active paid inference probes require a separate explicit user action and are not lifecycle startup behavior.

### Request transitions

Allowed states: `RECEIVED`, `ROUTED`, `UPSTREAM_PENDING`, `STREAMING`, `COMPLETED`, `FAILED`, `CANCELLED`. The allowed graph is exactly the one in the architecture document. Compare-and-set terminalization ensures only one of completion/failure/cancellation wins. Attempts do not reset request state to `ROUTED`.

## Errors

Canonical envelope:

```json
{
  "error": {
    "type": "router_error",
    "code": "route_not_found",
    "message": "No eligible route is configured for this request.",
    "param": "model",
    "request_id": "req_<uuidv7>",
    "retryable": false
  }
}
```

| Code | HTTP | Retryable by client | Meaning |
|---|---:|---|---|
| `invalid_request` / `unsupported_parameter` | 400 | no | syntax/semantic validation |
| `unsupported_capability` | 422 | no | route cannot preserve required semantics |
| `authentication_required` / `authentication_invalid` | 401 | no | local client auth failure |
| `secret_scope_violation` | 403 | no | reference not authorized for provider |
| `route_not_found` / `route_disabled` | 404/503 | no | no explicit eligible mapping |
| `idempotency_conflict` | 409 | no | same key, different normalized request hash |
| `request_too_large` | 413 | no | configured size limit |
| `rate_limited` | 429 | maybe | local/upstream rate policy |
| `secret_missing` | 503 | after operator action | secret reference cannot resolve |
| `provider_timeout` | 504 | policy dependent | deadline exceeded before terminal response |
| `provider_unavailable` | 502/503 | policy dependent | safe normalized upstream failure |
| `router_port_in_use` / `router_already_running` | startup error | no | process ownership/bind failure |
| `config_corrupt` / `state_corrupt` | startup 503 | no | recovery/rollback required |
| `cancelled` | 499-equivalent internal; transport may close | no | client/deadline/shutdown cancellation |
| `internal_error` | 500 | no by default | redacted invariant failure |

Raw upstream response bodies are not returned unless a protocol adapter explicitly validates and normalizes them. Messages are stable and content-free. Safe provider request IDs may be retained in authenticated traces, never in public health.

## Retry contract

`RetryPolicy` fields: `policy_id`, `max_attempts`, `base_delay_ms`, `max_delay_ms`, `jitter`, allowed failure categories/statuses, `respect_retry_after`, and `requires_idempotency`.

Safe default: at most two total attempts on the same provider route and endpoint, only before downstream output, only for transient connect failures, 408/429, or selected 5xx, and only when cancellation/deadline allow. `Retry-After` is bounded by total deadline. Authentication, validation, secret, capability, most 4xx, cancellation, and deterministic provider errors are not retried.

Provider adapters report failure facts; they do not retry. Streaming cannot retry after the first downstream SSE event/byte. Tool-call side effects are client-owned, but replaying a request can still bill or generate duplicate calls, so idempotency guards remain mandatory.

## Timeout contract

`TimeoutPolicy` fields: `connect_timeout_ms`, `first_byte_timeout_ms`, `stream_idle_timeout_ms`, `attempt_timeout_ms`, `total_timeout_ms`, and `shutdown_grace_ms`. All are positive, bounded, and satisfy attempt <= total. Each retry receives the remaining total budget; it does not reset the deadline. Client cancellation wins immediately. Timeout errors record phase enum, not request content.

## Idempotency contract

- An `Idempotency-Key` is scoped to authenticated `client_id + route_id`.
- Router hashes the raw key and normalized semantic request; raw keys are never logged.
- Same key plus different request hash returns `idempotency_conflict` before upstream I/O.
- Same key plus a completed non-stream response MAY return the stored canonical result within configured TTL.
- In-progress duplicates either join a safe single-flight result or return conflict; behavior is fixed per config and tested.
- Streaming result replay and replay after observable partial output are deferred.
- Persistence is bounded, content-sensitive, disabled by default until its secure storage slice. Without persistence, safe retries require upstream idempotency support or no observable acceptance.

## Cancellation contract

Cancellation sources are client disconnect, caller token, total/phase deadline, lifecycle shutdown, or operator stop. The Core propagates one cancellation token through resolver (where relevant), secret resolution, adapter encoding, upstream transport, SSE writer, and meters. Cleanup is bounded and idempotent. Cancellation never activates fallback. Terminal race precedence is: already committed completion/failure remains; otherwise cancellation commits `CANCELLED`.

## Failover contract

`FailoverPolicy` explicitly distinguishes:

1. `same_provider_retry`: safe default may be ON within retry rules.
2. `same_model_alternate_endpoint`: OFF unless named endpoints and equivalence/security boundaries are configured.
3. `same_model_alternate_provider`: OFF unless exact model identity and capabilities are explicitly approved.
4. `cross_model_fallback`: **OFF by default** and requires an ordered model-route allowlist plus explicit operator configuration.

Failover is forbidden after downstream output, on cancellation, across disallowed secret/data/auth scopes, or to a route lacking required tool/reasoning/streaming capabilities. Every attempt has an `attempt_id`; `fallback_count` excludes same-route retry. The final response/trace identifies the actual route through safe Router metadata.

## Circuit breaker contract

Breaker key is `(provider_route_id, endpoint_id, model_route_id)` and never global by brand. States are `CLOSED`, `OPEN`, `HALF_OPEN`, with versioned thresholds and monotonic time. V1 implementation boundary keeps breakers disabled until LR-11. Breakers influence eligibility but never rewrite config/health or enable fallback. Manual reset is authenticated and deferred until an administrative API is designed.

## Streaming and SSE contract

- Preserve event order, response ID, item IDs, tool call IDs, deltas, completion, and usage events.
- Parse arbitrary network fragmentation and multiple events per read; enforce event and buffer limits.
- Emit only valid UTF-8 SSE frames; flush with bounded backpressure.
- Comments/keepalives contain no state or content.
- First downstream event marks the no-retry/no-failover checkpoint.
- Unexpected EOF after output is a terminal stream error, not a complete response.
- Client disconnect cancels upstream and suppresses further writes.
- Trace captures event types/timing/counts, never event payloads.

Golden fixtures define canonical non-stream and stream equivalence. Background, resumable, and stored Responses are deferred.

## Reasoning and tool contracts

Reasoning summaries and opaque reasoning items are preserved only when both canonical and upstream adapters declare an exact mapping. They are never downgraded into assistant text or logged. Unsupported reasoning controls fail `unsupported_capability`/`unsupported_parameter`.

Function definitions, tool choice, tool call IDs, function names, JSON argument bytes/structure, and tool results must round-trip. Router validates size/shape but never executes a tool or interprets project paths. Loss of a tool call ID or conversion to plain text is a contract failure.

## Multimodal boundary

V1 core recognizes canonical content-part types so it can reject unsupported input deterministically. No adapter may fetch arbitrary URLs, read local files, or decode images by default. Images/multimodal become usable only in a later slice that defines byte/URL/file security, size/media validation, retention/redaction, provider mapping, streaming, and fixtures. Audio/video are deferred.

## Observability contract

Allowed default fields:

```text
request_id trace_id attempt_id route_id provider_id model_id endpoint_id
request_state status_code latency_ms ttft_ms input_tokens output_tokens
cached_tokens reasoning_tokens cost_estimate currency retry_count fallback_count
normalized_error config_generation adapter_versions timestamps
```

Forbidden default fields:

```text
prompt/input/output/reasoning text; tool arguments/results; image/audio bytes or URLs;
API keys; local/upstream Authorization; Cookie/Set-Cookie; raw query strings;
environment dumps; auth.json; .env content; user project secrets or source paths.
```

The redaction pipeline uses typed allowlist serialization, header denylist, secret-handle non-stringability, pattern defense-in-depth, and sink-level recheck. It returns `Redacted<T>`, the only type accepted by log/trace sinks. Failure drops the event. Debug mode cannot disable secret/content prohibition; explicit future content capture requires a separate security design and is out of scope.

Retention/rotation are user config with restrictive maximums; defaults are bounded. Request log and trace are separate: log is durable safe summary, trace may be bounded in-memory plus safe diagnostic export. Neither is a conversation store.

## Health contract

- Startup probe: config schema, feature flag, PID ownership, loopback bind, registry consistency, secret-reference syntax/existence (existence only), and at least one eligible route.
- No startup paid inference or provider request.
- Passive health: normalized request outcomes with thresholds and cooldown.
- Optional read-only provider model-list checks belong to an explicit later health action; they cannot approve/register/activate models.
- Missing secret marks affected route unavailable with safe reason but never reveals reference value.
- `READY` means admission is safe, not that every provider/model is healthy.
- `DEGRADED` means some noncritical routes/components are unavailable while at least one configured route can safely serve.

## Configuration, migration, and rollback contracts

Canonical locations:

```text
repo:  local-router/config/router.defaults.json
user:  ~/.codex/multimodel-manager/local-router/router.config.json
state: ~/.codex/multimodel-manager/local-router/runtime/
logs:  ~/.codex/multimodel-manager/local-router/logs/
backup:~/.codex/backups/local-router/<timestamp-id>/
```

Merge is deterministic and validated before use. Arrays with IDs merge by ID only where schema says so; otherwise replace. Duplicate IDs fail. Writes use temp + flush + atomic replace, optimistic `version`, backup hash, migration ID, and receipt. Migration is sequential, idempotent, and rejects unknown newer schemas. Corrupt user config is quarantined; safe defaults keep Router disabled. Rollback verifies the backup hash, restores exact prior files, and ends in Direct Mode/Router disabled. It never edits unrelated Manager blocks, user profiles, Desktop route, secrets, or projects.

## Feature flag and permission contract

Repository defaults:

```text
mode = direct
local_router.enabled = false
cross_model_fallback = OFF
listen_host = 127.0.0.1
```

Starting Router requires explicit user config plus local process ownership. Invoking Responses requires `responses:invoke`; status requires `router:status`; future administration requires a separate `router:admin` scope and endpoint design. Provider secret scope must include the selected provider. Route selection cannot elevate scopes. There is no anonymous protected endpoint.

## Direct Mode compatibility contract

The following are protected production boundaries through LR-11:

- `installer/scripts/launch-controller-model.ps1`
- `installer/scripts/desktop-chat-provider.ps1`
- `installer/scripts/desktop-chat-route.ps1` and any current generic Desktop provider route
- V4 Visual Console/UI runtime files
- active Manager provider definitions and Profile V2 migration behavior

Router absence, disabled config, startup failure, port conflict, corrupt Router state, or missing Router secret MUST leave Direct Mode byte-for-byte/behaviorally available. Integration begins only in LR-12/LR-13, remains opt-in, creates separate owned config, backs up before changes, and has exact rollback.

## Test and fixture contract

Planned repository fixture root is `tests/fixtures/local-router/v1/` with:

- `responses/nonstream-text`, `stream-text`, `reasoning`, `tool-call`, `tool-result`, `usage`, `normalized-errors`, `cancel-before-output`, `cancel-after-output`, and `unsupported-multimodal`;
- `routing/exact`, `priority`, `weighted-deterministic`, `disabled`, `unhealthy`, `ambiguous`, and all failover classes;
- `config/default-disabled`, N-1 migration, corrupt, duplicate ID, invalid host, conflict, and rollback receipts;
- `security/redaction`, forbidden headers/fields, secret missing/scope/rotation, browser Origin, and stale PID;
- `pricing/v4-projection`, cached price, unknown, stale, partial usage, and currency mismatch.

Unit and contract tests use fakes only. Integration tests bind only an ephemeral test loopback port and a fake upstream; they never use port 47821 by default, real provider URLs, user Codex config, keys, `auth.json`, or paid inference. Golden changes require explicit review and adapter contract-version assessment. Direct Mode regressions run in every slice release gate.

## Deferred contracts

Deferred means unusable, not silently approximated: Anthropic Messages/provider-specific Chat conversion; images/audio/video; background/stored Responses and explicit cancel endpoint; remote/network listening; browser UI/CORS; secret stores beyond environment references; persistent content/idempotency replay for streams; active paid health probes; automatic same-model alternate provider; cross-model fallback enablement UI; V4 UI and Codex Desktop integration; billing reconciliation.

## Contract Definition of Ready

An implementation slice is Ready only when its entities, schemas, IDs, versions, states, inputs/outputs, dependencies, adapter capabilities, errors, retry/timeout/idempotency/cancellation, state/checkpoints, observability, permissions, secrets, migration, feature flag, rollback, tests/fixtures/eval, release gate, build order, PR boundary, out-of-scope list, and slice DoD are identified in these documents without contradiction.

## Contract Definition of Done

A future implementation is Done only when it conforms to the pinned contract, passes unit/contract/integration/regression/golden tests, contains no secret/runtime state, preserves Direct Mode, documents deviations with a new version, provides rollback evidence, and its actual Development Gate CI run succeeds. Architecture validation alone does not satisfy runtime Done.

## LR-14P control-plane contracts (prerequisite, not a roadmap slice)

LR-14P is the corrective prerequisite integration work for LR-14 V4 UI. It is
not a new official roadmap slice and does not advance the formal roadmap past
16/18. LR-14P MUST NOT modify PR #84/V4 UI files, LR-12/LR-13 integration
semantics, provider adapters, routing/protocol algorithms, retry/failover/
circuit-breaker algorithms, pricing algorithms, or
`installer/scripts/launch-controller-model.ps1`.

### Endpoints

| Endpoint | Method | Scope | Purpose |
|---|---|---|---|
| `/v1/router/control-plane/status` | GET | `router:control-plane` | versioned control-plane status projection |
| `/v1/router/control-plane/usage` | GET | `router:control-plane` | bounded usage/cost projection (query `limit`, default 20, hard max 100) |
| `/v1/router/control-plane/requests` | GET | `router:control-plane` | bounded safe recent durable-request projection |
| `/v1/router/control-plane/policy` | GET/PUT | `router:control-plane` | configured/effective policy read and generation-aware mutation |
| `/v1/router/control-plane/feature` | PUT | `router:control-plane` | generation-aware `local_router.enabled` mutation |

Every control-plane endpoint reuses the existing local bearer-token boundary
plus the fixed `router:control-plane` scope. Unauthenticated requests return
401; a token whose client lacks the scope returns 403 `scope_denied`.

### Versioning and JSON schema

All control-plane DTOs carry `schema_version: 1` and are documented by
machine-readable schemas under `local-router/schemas/`:

- `control-plane-status.v1.schema.json`
- `control-plane-usage.v1.schema.json`
- `control-plane-recent-requests.v1.schema.json`
- `control-plane-policy.v1.schema.json`
- `control-plane-policy-mutation.v1.schema.json`
- `control-plane-policy-mutation-result.v1.schema.json`
- `control-plane-feature-mutation.v1.schema.json`
- `control-plane-feature-mutation-result.v1.schema.json`

The old `/v1/router/status` contract remains byte-compatible and is never
modified to add control-plane fields; PR #84 consumes the new projection.

### Usage/Cost semantics

- Reads come from the exact production `RequestMeteringStore` instance written
  by `ProductionCompletionObserver`; no second metering store is created.
- Unknown usage and unknown cost stay `null`/unavailable, never `0`.
- Cost is informational and always identified as an estimate, never billing
  truth (`scope: bounded_recent_records`,
  `billing_note: informational_estimate_not_billing`).
- Summary totals are grouped by currency; no cross-currency sum is produced.

### Recent-request semantics

- `DurableRequestLog.ReadRecentAsync(maxCount)` is a bounded read-only recent
  reader over Router-owned durable records only. It accepts no user path,
  query path, or absolute path.
- `maxCount` is clamped by the HTTP layer to `1..100`; the reader enforces the
  same hard ceiling and never scans more than a fixed window of files.
- Corrupt, oversized, truncated/partial, unknown-future-schema, unreadable, or
  rotated records are isolated and reported as degradation; a single bad
  record never 500s the endpoint and raw exception text is never returned.
- Only safe operational metadata is projected (IDs, times, duration, terminal
  state, HTTP status, safe error code, attempt/retry/fallback counts, stream,
  usage-present).

### Policy semantics

- Configured and effective policies are distinct in the read contract; absent
  bodies are reported as effective `safe_defaults`, never as "configured to
  the default".
- Mutation is generation-aware (CAS): stale `expected_generation` returns 409
  `control_generation_conflict`.
- Only existing LR-11 retry/timeout/failover fields are exposed. Body values
  are validated before an atomic write; failed writes preserve the previous
  valid config.
- Cross-model fallback is structurally HARD OFF: no configurable body or
  mutation field can enable it, and `cross_model_fallback: "HARD_OFF"` is
  always explicit.
- Production execution consumes policy bodies through the
  `IRouterExecutionPolicySource` composition seam
  (`ConfigRouterExecutionPolicySource`); policy algorithms are not modified.

### Feature semantics

- `PUT /v1/router/control-plane/feature` changes the minimum schema-coupled
  feature state (`local_router.enabled` + the `mode` marker required by the
  schema-v1 invariant). Routes, providers, clients, endpoints, policies, and
  all other schema-valid fields are preserved.
- Enable does not equal Start. The mutation response and control-plane status
  report `start_stop_available=false`,
  `lifecycle_reason_code=LIFECYCLE_CONTROL_GAP`; Runtime Start/Stop ownership
  remains deferred to LR-15.
- The core mutation operator is host-independent and never requires the Router
  HTTP server to be alive.

### Control-plane error allowlist

LR-14P adds the following fixed codes (no raw exception messages):

| Code | HTTP |
|---|---:|
| `control_invalid_request` | 400 |
| `control_policy_invalid` | 400 |
| `control_policy_not_found` | 404 |
| `control_generation_conflict` | 409 |
| `control_mutation_busy` | 409 |
| `control_read_unavailable` | 503 |
| `control_payload_too_large` | 413 |
| `control_feature_update_failed` | 500 |
| `control_mutation_failed` | 500 |

### Failure isolation and provider side effects

- Usage reader, recent reader, and policy projection failures degrade the
  control-plane status; they never stop Router serving and never fail a model
  request path.
- Control-plane reads and mutations never send provider requests, run model
  discovery, run provider probes, or perform paid inference.

### Round-two semantic hardening (same PR #87)

- **C1 — atomic generation CAS**: every mutation acquires a cross-process
  named-mutex `ConfigMutationGate` keyed by a SHA-256 hash of the canonical
  user-config path, re-reads the current config inside the gate, and performs
  the final generation compare under that serialization boundary. Concurrent
  same-generation mutations have exactly one winner; the loser receives
  `control_generation_conflict` (or the safe busy code).
- **C2 — live policy publication**: a `CurrentRouterState` published snapshot
  is shared by production execution (`CurrentRouterExecutionPolicySource`) and
  the control plane. A successful policy mutation persists and reloads first,
  then atomically publishes the new validated snapshot; the very next request
  on the same running service observes it. Failed/stale mutations never
  publish. Each logical request captures one policy view at its boundary.
- **C3 — live feature gate**: `/v1/responses` admission reads the same
  published feature state. After a successful disable, new requests fail
  closed (`router_disabled`, 503) before any provider call; in-flight requests
  complete under existing semantics. Re-enabling on an already-running host
  resumes admission; enable never equals Start.
- **C4 — payload hard limit**: policy/feature mutation bodies are limited to
  64 KiB with a known `Content-Length` pre-check and a bounded max+1 read for
  unknown/chunked lengths. Oversized bodies return 413
  `control_payload_too_large` before the operator runs.
- **B1 — real health composition**: control-plane status consumes a read-only
  `PassiveHealthSnapshotSource` over the exact `PassiveHealthTracker` used by
  production execution; no second tracker is created for the UI.
- **B2 — breaker truth**: Policy/Status contract expose
  `circuit_breaker: effective_state=disabled, configured=null,
  mutation_available=false`,
  `reason_code=CIRCUIT_BREAKER_POLICY_CONFIGURATION_GAP`. No breaker config
  boundary exists in this slice.
- **B3 — partial usage null semantics**: bounded-scope dimension totals are
  null whenever any record in scope has that dimension unknown; unknown is
  never folded into zero.
- **B4 — bounded recent candidates**: the durable recent reader keeps only the
  newest `MaxRecentScanFiles` candidates while enumerating; it never
  materializes an unbounded candidate array.
- **B5 — config preservation**: feature/policy mutations preserve all unrelated
  schema-valid fields (clients, routes, providers, endpoints, model routes,
  limits, other policies). Schema-v1 strictly rejects true unknown fields; no
  `JsonExtensionData` is used.

### Commit atomicity (final blocker closure)

- PERSIST → PUBLISH is one serialized commit inside the operator's
  `ConfigMutationGate`. The runtime publication sink is an optional operator
  binding; when a running Host is present it is the same `CurrentRouterState`
  shared by execution, the serving gate, and control-plane reads.
- The next generation is computed from the validated document BEFORE the
  atomic replace, and after the commit point no cancellable or failure-prone
  work remains: a post-commit `RequestAborted` can no longer leave disk newer
  than runtime.
- HTTP handlers never publish; they only validate requests, call the operator,
  and serialize results. Runtime publish occurs exactly once per successful
  mutation, inside the gate, before the gate is released.
- Mutation availability in control-plane status is not hard-coded: it is true
  only when the composed operator has a live publication sink bound to the
  same `CurrentRouterState` the ingress holds.
- Offline config mutation (an operator without a sink, e.g. used by another
  process) guarantees durable cross-process CAS only. It does not equal live
  running-host publication and never pretends to mutate another process's
  memory. No IPC is introduced; IPC/lifecycle coordination remains LR-15.
