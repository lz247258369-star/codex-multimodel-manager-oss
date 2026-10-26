# LR-14P — Local Router Control-Plane Contracts

LR-14P is the corrective prerequisite integration work for LR-14 V4 UI
integration. It is not a new official Local Router roadmap slice. The formal
roadmap remains **16 / 18** until LR-14 is actually merged.

## Scope

LR-14P provides:

- Usage / Cost safe read projection (bounded, versioned, authenticated)
- Recent request safe read projection (bounded, versioned, authenticated)
- Versioned Router Control-Plane status projection
- Policy read contract (configured vs effective)
- Generation-aware policy mutation operator
- Generation-aware Local Router feature enable / disable operator
- A stable, versioned, testable Control-Plane contract surface for the future
  LR-14 V4 UI

LR-14P does **not** provide:

- V4 UI / WPF / buttons / pages / charts
- Process Start/Stop lifecycle control
- Installer packages or release workflows
- LR-15 work

## Contract Inventory (base `69e2f8efa9e9debd089c81c014bc5bae6cff3553`)

The inventory below was completed against `main` before any code change.

### A. `/v1/router/status`

- Handler: `Router.Ingress.Handlers.StatusHandler` (GET)
- DTO: `RouterStatusPayload`, JSON schema `schemas/router-status.v1.schema.json`
- Schema version: fixed `schema_version = 1`, `additionalProperties = false`
- Authentication boundary: shared bearer token middleware; scope
  `router:status` enforced in the handler
- Payload: lifecycle, ready, config generation, in-flight count,
  `local_router_enabled`, supported contracts, empty route list

### B. Local Router token authentication

- Bearer token resolved through `Router.Secrets` LR-2 secret resolver
  (`LocalRouterSecrets.CreateTokenReference`), fixed-time comparison
  (`TokenAuthenticator`)
- One local token reference per config (`local_router.client_auth.token_ref`)
- No second token/secret/auth system is introduced by LR-14P

### C. Configuration system

- Immutable `RouterConfig` + `EffectiveRouterConfigSnapshot`
- `RouterConfigurationLoader`: defaults + user merge → normalize → validate →
  stable lowercase SHA-256 `config_generation`
- Validation is fail-closed (`RouterConfigValidator`); arrays/scalars replace
  defaults (`RouterConfigMerger`); unknown fields are rejected
- No user-config writer existed before LR-14P; the new operator writes the
  full validated effective document atomically (temp + replace) and re-loads
  to compute the next generation

### D. Policy configuration schema

- `policies[]` entries contained only `policy_id` + `version`
- No retry/timeout/failover/circuit-breaker bodies existed
- LR-14P adds optional versioned `retry`, `timeout`, and `failover` bodies
  inside policy entries (additive schema evolution; old documents still load)

### E. LR-11 policy types

- `Router.Policies.RetryPolicy` (max attempts, base/max delay, jitter,
  retry-after handling)
- `Router.Policies.TimeoutPolicy` (connect/first-byte/idle/attempt/total)
- `Router.Policies.FailoverPolicy` (`AllowCrossModelFallback` is hard OFF;
  `Create` refuses cross-model enable)
- `Router.CircuitBreaker.CircuitBreakerPolicy` (separate, disabled default;
  no route-level config seam exists, so LR-14P does not expose breaker
  mutation)
- `Router.Execution.RouterExecutionPolicySet` (retry + timeout + failover;
  `SafeDefaults`)

### F. How production execution receives policies

- `RouterExecutionResponsesService` holds one `RouterExecutionPolicySet`
  supplied through its constructor/factory
- `RouterHostBootstrap` did not supply one, so production always used
  `RouterExecutionPolicySet.SafeDefaults`
- LR-14P adds a per-route `IRouterExecutionPolicySource` composition seam at
  the factory; policy algorithms are not modified

### G. Production metering store (LR-10R)

- `RequestMeteringStore`: bounded (500 default / 1000 max), thread-safe,
  request-id idempotent, `Recent(maxCount)`
- `RequestMeteringRecord`: typed safe record; usage/cost stay null when
  unknown; cost estimates are always marked `estimated`
- LR-14P reads the same `RequestMeteringService.Store` instance written by
  `ProductionCompletionObserver`; no second metering store is created

### H. Durable request log

- `DurableRequestLog` had `WriteAsync`, `WriteSafeAsync`, `Snapshot`, and
  `RecoverCorruptAsync` only
- LR-14P adds a bounded, read-only `ReadRecentAsync` safe recent reader

### I. Safe request records

- `SafeRequestRecord` / `RedactedRequestRecord` contain operational metadata
  only (ids, times, terminal state, HTTP status, safe error code, attempt
  counts, usage-present marker, stream flag)
- No prompt/output/tool/header/secret/path fields exist by construction

### J. Lifecycle owner

- `RouterLifecycle` is the ingress state machine (STOPPED → STARTING → READY →
  STOPPING → STOPPED), driven by host start/stop signals
- There is no formal Control-Plane Start/Stop/Restart owner
- `LIFECYCLE_CONTROL_GAP = YES` (owned by LR-15); the control-plane status
  reports `start_stop_available = false` with that reason code and never fakes
  a Start/Stop capability

## Architecture prerequisite check

`LR14P_ARCHITECTURE_PREREQUISITE = NO`

Every core requirement can reuse an existing bounded, typed, fail-closed
system plus a composition seam. LR-14P does not rewrite the Router
architecture, replace the configuration system, reimplement LR-11 policy
algorithms, reimplement LR-10 pricing, or reimplement provider execution.

## Round-two semantic hardening (same PR #87)

- `ConfigMutationGate`: cross-process named-mutex serialization with hashed
  path identity; the final generation CAS occurs inside the gate after a fresh
  read (C1).
- `CurrentRouterState` publication shared by the serving feature gate, live
  policy resolution, and control-plane reads; policy/feature mutations persist
  first, then atomically publish (C2/C3).
- Live policy mutation and live feature disable are verified on ONE running
  service instance without restart in E2E.
- Control-plane mutation bodies have an independent 64 KiB hard limit (413
  `control_payload_too_large`) with a bounded read for chunked bodies (C4).
- Real passive health from the production `PassiveHealthTracker` is exposed
  read-only in control-plane status (B1).
- Circuit breaker is truthfully represented as disabled/not-mutable with
  `CIRCUIT_BREAKER_POLICY_CONFIGURATION_GAP = YES` (B2).
- Partial unknown usage dimensions keep totals null in summaries; durable
  recent reads keep bounded top-K candidates; unrelated schema-valid config
  fields are proven preserved by before/after tests (B3/B4/B5).
- Final blocker closure: PERSIST → PUBLISH is one serialized commit inside the
  operator mutation gate; HTTP handlers no longer publish; a post-commit
  cancellation cannot leave disk newer than runtime; mutation availability is
  reported truthfully (false without a live publication boundary).

Offline config mutation (operator without a live publication sink) guarantees
durable cross-process CAS only and does not equal live running-host
publication. No IPC is introduced; IPC/lifecycle coordination remains LR-15.
