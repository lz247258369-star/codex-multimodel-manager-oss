# HS-1B Router Thread-Scoped Model Override

Status: **DESIGN GATE ONLY — no implementation, no production behavior change.**

Revision: blocker-closure round (Safe Restore conflict, capture semantics,
feature enable path, identity ambiguity) — see §37.1.

Formal LR roadmap: **17 / 18** (unchanged). This is a capability extension
(`HS-1B`), **not** LR-15, and it does not alter the LR-15 boundary
("Hardening/packaging/release evidence only; feature expansion requires new
roadmap").

Baseline: `main` = `e3d60a8eeffe0e4a74bc899a93b97aaff222dc0e`.
Research branch `research/hot-switch-feasibility-gate` (design commits only).

Verified inputs this design builds on (no new runtime evidence claimed here):
`docs/HOT_SWITCH_FEASIBILITY_GATE.md` §6 (app-server per-turn model override),
§9 (Router-visible thread identity headers), §15 (Final Desktop Closure Gate:
`thread/resume` ignores model overrides on loaded threads; no attachable Windows
Desktop app-server control channel).

## 1. Goal

Give a Codex Desktop conversation a **Router-effective model** that the user can
change from the V4 Manager, without restarting Codex, creating a conversation,
patching Codex, editing `config.toml`, or touching the Codex database:

```
Codex Desktop thread T (native input box, unchanged)
        │  POST /v1/responses  (model = A as Codex knows it)
        ▼
Local Router  ──  thread T override = B (explicit user selection)
        │
        └─► provider route resolved for B, executed, traced as A→B
```

After the switch, **T's next ordinary user turn and every following ordinary
turn on T resolve to B**, until B is superseded, cleared, expired, or the Router
process ends. Other threads are unaffected.

## 2. Non-goals

- No change to Codex / Desktop / CLI, no `model/list` injection, no picker work.
- No change to the Codex thread's own `ThreadSettings` (Codex still believes the
  requested model is A — see §13 "dual truth").
- No reasoning-effort switching (see §15).
- No SQLite/rollout/config mutation by the Router.
- No new provider adapters, no catalog expansion, no cross-model failover.
- No durable persistence of thread selection (see §10).

## 3. Evidence / why this path

| Path | Verdict | Evidence |
|---|---|---|
| Desktop native picker for custom Router models | UNSUPPORTED | gate §8 (catalog-only `model/list`, no config extension point) |
| `thread/resume(model=…)` for a **loaded** Desktop thread | FAIL | gate §15.3 (override silently ignored; next plain turn stayed A) |
| `thread/resume(model=…)` for an inactive/unsubscribed thread | PASS but unusable on the Windows Desktop | gate §15.4–15.6; no attachable Desktop app-server control channel (§15.7) |
| `turn/start(model=…)` | works, but requires injecting user input via a channel that does not exist | gate §6, §15.8 |
| **Router-side thread-scoped override** | selected | the Router is already on every `/v1/responses` hop and already receives `thread-id` / `x-codex-turn-metadata` (gate §9) |

## 4. Existing components reused (real code)

| Concern | Existing component | Verdict |
|---|---|---|
| Request entry | `local-router/src/Router.Ingress/Handlers/ResponsesHandler.cs`, `ResponsesIngress.cs` (`MapPost("/v1/responses")`, middleware chain) | EXTEND |
| Per-request data carrier | `local-router/src/Router.Core/Context/RequestContext.cs` | EXTEND |
| Canonical request DTO | `local-router/src/Router.ClientAdapters.Responses/CanonicalResponsesRequest.cs` (`Model`, `Reasoning`, `Tools`, `Metadata`) | EXISTS (unchanged) |
| Model → route mapping | `Router.Registries/RouterRegistrySnapshot.TryResolveModel(providerId, clientModelId)`, `Router.Routing/RouteResolver.cs`, `RouteRequest.cs` | EXISTS (reused, unchanged signatures) |
| Capability gate | `Router.Execution/RouterExecutionResponsesService.RequestCapabilities` + `CapabilitySet` intersection | EXISTS (reused) |
| Execution + attempt metadata | `RouterExecutionResponsesService`, `ResponsesExecutionMetadata` | EXTEND |
| Control plane | `Router.Ingress/Handlers/ControlPlaneHandlers.cs`, `ControlPlane/ControlPlanePayloads.cs`, `Router.Core/Errors/ControlPlaneErrors.cs`, `local-router/schemas/control-plane-*.v1.schema.json` | EXTEND |
| Control-plane auth/limits | `ClientScopeRegistry` (`router:control-plane`), `AuthenticationMiddleware`, `BodyLimitMiddleware`, `MaxControlPlaneMutationBytes` | EXISTS (reused) |
| Observability | `Router.Observability/SafeRequestRecord.cs`, `Trace.cs`, `DurableRequestLog.cs`, `RedactionBoundary.cs` | EXTEND |
| Live state publication | `Router.Configuration/CurrentRouterState.cs`, `IRouterConfigPublicationSink`, `CurrentRouterExecutionPolicySource` | EXISTS (pattern reused for a second, **independent** store) |
| Composition | `Router.Host/RouterHostBootstrap.cs`, `Router.Execution/RouterExecutionServiceFactory.cs` | EXTEND |
| V4 control client | `installer/scripts/visual-router-runtime.ps1` (`Invoke-RouterV4ControlPlaneCall`, `Invoke-RouterV4StatusWorker`, `Invoke-RouterV4MutationWorker`, `Apply-RouterV4SnapshotToUi`), `installer/ui/visual-console.xaml` (`NavRouter` page, `RouterModelCombo`, `RouterEffortCombo`, `RouterRefreshButton`) | EXTEND |

No second registry, second resolver, second control plane, second auth system,
second trace sink, or second metering store is introduced anywhere in this
design (`tests/validate-local-router-lr14p-control-plane.ps1` already fails the
build for duplicate stores/trackers; HS-1B must not violate that).

## 5. Thread identity contract

### 5.1 What the Router actually receives today

Real ingress header reads (`rg` over `local-router/src`): only `Authorization`,
`Content-Encoding`, `X-Request-Id`, `traceparent`, `Origin`, and
`Idempotency-Key` (`ResponsesHandler.cs:45`, `AuthenticationMiddleware.cs:23`,
`BodyLimitMiddleware.cs:25`, `CorrelationMiddleware.cs:26-27`,
`OriginPolicyMiddleware.cs:26`). **No `thread-id`, no `session-id`, and no
`x-codex-*` header is read anywhere today**, so no `CanonicalThreadId` exists yet.

Observed on the wire (gate §9, captured from a loopback fake provider):

```
thread-id: <uuid>
session-id: <uuid>
x-codex-window-id: <uuid>:0
x-client-request-id: <uuid>
x-codex-turn-metadata: {"installation_id":…,"session_id":…,"thread_id":…,
  "turn_id":…,"window_id":…:0,"window_number":0,"context_window_id":…,
  "request_kind":"turn","root_turn_id":…,"sandbox":…,"sandbox_mode":…}
```

### 5.2 `CanonicalThreadId` (NEW, in `Router.Core`)

Two identity-bearing sources exist:

- **SOURCE A** = `thread-id` request header.
- **SOURCE B** = `x-codex-turn-metadata.thread_id` (requires the metadata header
  to parse successfully).

The complete truth table below is normative; there is no third source and no
inference path.

| Case | SOURCE A (`thread-id`) | SOURCE B (metadata `thread_id`) | Result |
|---|---|---|---|
| 1 | valid | absent | **ACCEPT A** |
| 2 | absent | valid, metadata parses, `thread_id` valid | **ACCEPT B** |
| 3 | valid | valid and canonical-equal | **ACCEPT** |
| 4 | valid | valid but canonical-**different** | **FAIL CLOSED** — no observation, no selection lookup, no pending consumption; the request is served with the Codex requested model; trace records `control_thread_identity_mismatch` |
| 5 | valid | metadata header present but malformed / oversized / `thread_id` invalid | **FAIL CLOSED** — A is *not* used as a silent fallback |
| 6 | **malformed** | valid | **FAIL CLOSED** — a broken presented A is never ignored in favour of B |
| 7 | malformed | absent | **NO IDENTITY** |
| 8 | absent | metadata malformed / oversized | **NO IDENTITY** |
| 9 | absent | absent | **NO IDENTITY** |

**Principle:** once both identity-bearing sources are presented, *any* malformed
or mismatching source fails the request's identity closed. One source may never
mask a defect in the other. "NO IDENTITY" and "FAIL CLOSED" both mean the
request is served with the Codex requested model and can neither observe a
thread nor consume/activate a selection.

Additional rules:

- `session-id`, `x-codex-window-id`, and `x-client-request-id` are **never**
  identity and never a fallback.
- The "most recent thread" is **never** identity.

Validation (`CanonicalThreadId.TryParse`):

- allowlist charset `[0-9a-fA-F-]`, length 8–64, at least one hex digit run;
- canonical form = ASCII-lowercased, stored as an opaque string and compared
  with `StringComparison.Ordinal` on the canonical form (case-safe: two casings
  of one id are the same thread, never two distinct threads);
- never parsed into a GUID, never interpreted as text, never used in a file
  path, never concatenated into a cache key without hashing (§17);
- `x-codex-turn-metadata` is parsed only for `thread_id` and `request_kind`; the
  header is bounded (≤ 4096 bytes) and an oversized or unparseable value yields
  *no identity* (fail closed) — never a guessed default.

### 5.3 `ThreadRef` (external identity)

`ThreadRef = lowercase hex( SHA-256( canonicalThreadId ) )[:16]`.

- The **raw canonical thread id exists only inside in-process state and the
  request pipeline**. It is never written to the durable request log, never
  returned by the control plane, never shown in the V4 UI, and never placed in
  an error message.
- Every external surface (control-plane reads, mutations, traces, V4 UI) uses
  `ThreadRef` only. If two distinct canonical ids ever map to the same ref, the
  entry is not registered and the request is served normally (fail closed, never
  merge identities).

## 6. Observed thread registry (NEW `Router.ThreadSelection`)

Bounded, in-memory, metadata-only. One entry per canonical thread id:

| Field | Notes |
|---|---|
| `ThreadRef` | external id (§5.3) |
| `ClientId` | `RequestContext.ClientId` (for example `client.codex_desktop`) |
| `FirstSeen` / `LastSeen` | UTC |
| `LastRequestKind` | wire value, allowlisted token, `null` when absent |
| `LastRequestedModel` | the model string Codex sent |
| `LastSelectedModel` | what the Router actually resolved for that request |
| `WindowNumber` | nullable int, only when the metadata carried it |
| `Selection` | state (§8), generation, model, issued/expires, last failure code |

**Never stored:** prompt, response, reasoning text, tool arguments, file
content, `cwd`, conversation title, auth material, provider keys, raw header
values, raw metadata JSON.

Bounds (proposed defaults, with hard ceilings in code alongside
`ConfigLimitCeilings`):

| Bound | Default | Hard ceiling |
|---|---|---|
| observed threads | 128 | 256 |
| metadata header bytes parsed | 2048 | 4096 |
| thread id length | 36 | 64 |
| entry idle TTL | 24 h | 7 d |
| eviction | last-seen LRU when full | — |

Registry insertion is refused (the request is still served normally) when the
store is full and every entry is newer than the idle TTL, so a malformed or
fake-id flood can never grow memory without bound.

## 7. Discovery / capture UX

Three options were evaluated as required.

| Option | Assessment | Verdict |
|---|---|---|
| **A. Recent observed threads** — the Router lists threads it has already seen on normal traffic | zero extra user steps, works for any thread used since the Router was enabled, metadata-only, a stale list is harmless | **PRIMARY** |
| **B. Capture next user turn — identity discovery only** — the user clicks "identify the current Codex conversation" and the Router binds the next eligible `request_kind == "turn"` **to a `ThreadRef` only** | needed when the target thread has not been observed yet or the user cannot identify their thread in the list; needs a bounded window and strict eligibility | **FALLBACK** |
| **C. Auto-select most recent thread** | ambiguous the moment two windows or threads are active; silently picks the wrong conversation; violates "never guess" | **REJECTED** |

### 7.1 Primary flow (Option A)

1. V4 opens the Router page section "Observed Codex threads" (read-only refresh;
   **no provider call and no mutation**).
2. The user picks a row (`ThreadRef`, last seen, Codex requested model, Router
   effective model, selection state).
3. The user picks an approved Router model from the existing approved-model
   list (the same source the V4 model matrix already uses; §14).
4. "Switch this conversation's model" → `PUT …/threads/{ref}/selection`.
5. The row shows `PENDING` until the thread's next eligible turn, then `ACTIVE`.

### 7.2 Fallback flow (Option B) — capture is **identity discovery only**

Capture answers exactly one question: *"which Router-observed Codex thread is
this?"* It never selects, changes, or implies a model.

1. V4: **"识别当前 Codex 会话"** → `POST …/threads/capture` returns
   `capture_token` and `expires_at` (default 120 s, bounded).
2. The user sends one ordinary message in the target conversation.
3. The Router binds the first eligible `request_kind == "turn"` request to a
   `CanonicalThreadId`/`ThreadRef` and moves the capture `OPEN → CAPTURED`.
   Safe projection returned/stored: `thread_ref`, `last_seen`,
   `requested_model`, `effective_model`, `client_id`, `capture_status`. **No
   selection state is created or modified.**
4. The captured turn itself **must** use the normal requested model: capture
   changes neither the route nor the model of that turn.
5. V4 shows: `已识别会话：<ThreadRef>` with `Codex 请求模型：A` and
   `Router 当前生效模型：A` (or the thread's pre-existing selection, if any).
6. Only after the user explicitly picks model `B` and presses
   **"切换此会话模型"** does `PUT …/threads/{threadRef}/selection`
   (`schema_version`, `expected_generation`, `model = B`) run, moving the thread
   from `NONE`/existing state to `PENDING`; the next eligible user turn then
   performs `PENDING → ACTIVE` (§9).

The capture window is single-claim (one CAS), so two simultaneous eligible turns
produce exactly one winner; the loser is served normally with the Codex
requested model and is **not** mutated. Expired or abandoned tokens are removed,
never durable, never listed after expiry, and never silently applied later. If a
capture expires without a claim the UI must say exactly that; no fallback thread
is chosen.

### 7.3 Capture hard rules

```
CAPTURE_MUTATES_MODEL_SELECTION = MUST NO
CAPTURE_PROVIDER_CALLS          = 0
CAPTURE_CURRENT_TURN_MODEL_CHANGE = NO
CAPTURE_CREATES_PENDING         = MUST NO
CAPTURE_CREATES_ACTIVE          = MUST NO
```

A wrongly captured thread therefore cannot change any model by itself; the user
must still choose a model explicitly. **At most one OPEN capture exists per
Router process**; tokens are single-claim, TTL-bounded, and cancellable, and the
`CAPTURED` result is retained for a short read TTL so V4 can read it.

The capture window is globally unique rather than one-per-control-plane-client
because an incoming Codex turn carries no trustworthy owner-correlation key: it
presents a `CanonicalThreadId`, a `request_kind`, and the Codex client identity,
but nothing that could tell the Router whether *this* turn belongs to control
owner A or owner B. Two parallel OPEN windows could therefore never be
disambiguated safely (window number, session id, "latest thread", source IP, and
arrival order are all explicitly rejected as guesses). A second `POST
…/threads/capture` while a window is OPEN fails closed with
`control_thread_capture_busy` (HTTP 409) and never cancels, replaces, or reveals
the existing window - not even for the same owner. The owner (`OwnerClientId`)
is retained purely as **read/cancel authorization**: only the authenticated
control-plane client that opened a window may `GET` or `DELETE` its token, and a
foreign owner receives exactly the same `control_thread_capture_not_found`
(HTTP 404) as an unknown token so capture existence is never disclosed.

Capture state is TTL-bounded and lazily expired, never by a timer: an `OPEN`
window whose capture TTL elapsed, and a `CAPTURED` result whose retention TTL
elapsed, are both removed at the next read/claim/mutation, using the inclusive
boundary rule (`now >= expires_at`). An expired token is therefore
indistinguishable from an unknown token (HTTP 404, never a `capture_expired`
code, never a successful cancel), and an expired `OPEN` window no longer occupies
the single slot, so the next `POST .../threads/capture` succeeds instead of
returning `control_thread_capture_busy`. Capture expiry touches no observed
thread and no model selection: capture lifecycle and selection lifecycle are
independent.

The number of retained capture entries is additionally **hard bounded** by the
observed-thread registry cap (`MaxObservedThreads`, no new user-facing setting):
at most one `OPEN` window plus the retained `CAPTURED` results within that count.
Expired entries are removed first; if the ceiling is still reached when a new
window is opened, the deterministic oldest `CAPTURED` result is evicted using
`captured_at` (falling back to `created_at`) as the retention timestamp, with the
monotonic capture creation sequence as the tie-breaker for equal timestamps. The
random capture token never participates in eviction ordering, so it can never
decide the outcome. The live `OPEN` window is **never** evicted under
retained-count pressure, and capture eviction never mutates observed threads or
model selections.

## 8. Override state machine

States: `NONE`, `PENDING`, `ACTIVE`, `SUPERSEDED`, `CLEARED`, `EXPIRED`.

```
NONE    ──set(B)──────────► PENDING
PENDING ──eligible turn───► ACTIVE                (one-shot claim, CAS)
PENDING ──expires─────────► EXPIRED ──set(C)────► PENDING
PENDING ──set(C)──────────► PENDING               (generation+1, B superseded)
ACTIVE  ──set(C)──────────► PENDING               (generation+1, B superseded)
ACTIVE  ──clear───────────► CLEARED
ACTIVE  ──idle TTL────────► EXPIRED
any     ──process end─────► state destroyed (restart = NONE)
```

`SUPERSEDED`, `CLEARED`, and `EXPIRED` are terminal audit records; a new `set()`
always creates a fresh `PENDING` with a new generation.

Capture (§7.2) is **not** a transition in this machine: it never creates
`PENDING`, never creates `ACTIVE`, and never changes `selection_model`.

Semantics:

- `PENDING`: the user selected B and the target thread has not yet produced its
  first eligible ordinary turn.
- `ACTIVE`: that first eligible turn used B, **and every following ordinary turn
  of that thread resolves to B**. The state is sticky, not one-shot.
  **One-shot deletion is explicitly forbidden**: a consumed pending must never
  degrade the next turn back to A.
- `SUPERSEDED`: B was replaced (record kept: model, generation, timestamps).
- `CLEARED`: the user restored the Codex requested model.
- `EXPIRED`: pending TTL (§11) or active idle TTL (§10) elapsed.

## 9. Pending → Active semantics

The claim happens in the execution path, before `RouteRequest.Create`:

1. `PENDING` exists **only** because the user explicitly issued
   `PUT …/threads/{ref}/selection` (never because of capture or inference).
2. Identity present, `request_kind == "turn"`, thread state `PENDING`, and not
   expired ⇒ atomic CAS `PENDING → ACTIVE` (generation +1); `LastRequestedModel`
   is recorded from the incoming request.
3. State `ACTIVE` and `request_kind == "turn"` ⇒ no state change; resolve with
   the selected model.
4. Any request whose `request_kind` is not exactly `"turn"` resolves with the
   Codex requested model, regardless of `PENDING`/`ACTIVE` state (§12).
5. The claim is **exactly once**: concurrent requests race on the CAS, one wins,
   and the others observe `ACTIVE` and resolve to the same selected model.
6. A request that fails *after* claiming never rewrites the state machine
   (§14, §25); the state stays `ACTIVE` and the failure is recorded.

**Precise `ACTIVE` semantics:** `ACTIVE` means *every future eligible request —
that is, every request on that `CanonicalThreadId` with `request_kind == "turn"` —
uses `selection_model = B`.* It does **not** mean that auxiliary requests on the
thread also use B; those always use the Codex requested model.

## 10. Active lifetime decision

| Option | Pros | Cons |
|---|---|---|
| A. Until user clear/switch | perfectly aligned with user intent | unbounded state for a long-running process; an armed override is easy to forget |
| **B. Router process lifetime** | no durable persistence, no migration, no privacy surface, deterministic restart semantics (restart ⇒ Codex requested model again) | a config-driven Router restart silently drops the selection |
| C. Idle TTL | bounds staleness | if too aggressive, the "sticky" expectation breaks mid-session |
| D. Conversation/session-inferred lifetime | — | requires Codex DB/state knowledge this project must not read |

**Decision — `ACTIVE_OVERRIDE_LIFETIME` = Router process lifetime, bounded by an
explicit idle TTL.**

- Storage: in-memory only. Never on disk, never in the config file, never in
  SQLite, never in the Router state file.
- Defaults: `active_idle_ttl_ms` = 24 h; `pending_ttl_ms` = 300 s.
- Restart semantics: **process restart clears every selection** and threads
  immediately return to the Codex requested model. This is documented UI
  behavior, not an accident.
- No durable option is introduced by this design. Durability, if ever wanted,
  must be a separate approved slice with storage, migration, privacy, and
  cleanup design.

## 11. Pending TTL

- `pending_ttl_ms` default 300 000, floor 30 000, ceiling 1 800 000.
- Set at mutation time: `issued_at`, `expires_at = issued_at + ttl`, `generation`.
- An expired pending can never be consumed: the claim checks `now < expires_at`;
  expiry performs `PENDING → EXPIRED` and the request is served with the Codex
  requested model.
- `issued_at`, `expires_at`, and `generation` are part of the read projection so
  the UI can show a countdown and an explicit expired row.
- The active idle TTL is a **separate** knob (§10) and never shortens a pending
  window.

## 12. `request_kind` gate

| Incoming `request_kind` | Behaviour |
|---|---|
| `"turn"` | the **only** eligible kind: may claim `PENDING`, and the only kind that applies an `ACTIVE` selection |
| any other known token (title generation, summary/probe, background metadata, health, tool-support probe) | safe observation is allowed (`last_seen` only); **never** consumes `PENDING`, never activates, never applies an `ACTIVE` selection — it always uses the Codex requested model |
| missing / unparseable / unknown | safe observation may still update `last_seen` once identity is valid, but for **model selection** the behaviour is identical to any non-`turn` kind: requested model only. The trace records `control_thread_selection_invalid_request_kind` as an informational code |

Rules that follow directly:

- A non-`turn` request must never flip a thread from `PENDING` to `ACTIVE`.
- A non-`turn` request must never change which model an `ACTIVE` thread resolves
  to; in particular, background metadata/probe requests are **not** rewritten to
  B (that would silently change Codex's auxiliary traffic).
- Missing or unknown `request_kind` is treated by the model-selection path
  exactly like a non-`turn` kind.

## 13. Incoming `requested_model` vs override (request truth)

For every request the Router records, at minimum:

```
requested_model     = incoming request.Model     (Codex's own truth, never rewritten)
selected_model      = model actually resolved    (A when no override, B when overridden)
selection_source    = none | thread_pending | thread_active
override_generation = <uint64> | null
request_kind        = turn | <other> | null
thread_ref          = 16-hex hash | null
```

`requested_model` is **never** overwritten with B. Recording
`requested_model = B` in the audit trail is forbidden: the dual truth is exactly
what makes the switch explainable, auditable, and reversible.

## 14. Resolution pipeline and capability checks

```
ResponsesHandler
  → parse CanonicalResponsesRequest (unchanged)
  → read + validate thread identity into RequestContext              [EXTEND]
  → IResponsesService.InvokeAsync(request, context, ct)
       → ThreadSelectionStore.Resolve(context, request)              [NEW]
            · identity + request_kind gate (§12)
            · claim / sticky decision (§9)
            · returns { requested_model, selected_model, source, generation }
       → RouteRequest.Create(clientId, selected_model, requiredCapabilities)  [EXISTS]
       → RouteResolver.Resolve(...)                                          [EXISTS]
       → provider harness / upstream transport / SSE / metering              [EXISTS]
```

Static checks at mutation time (V4 selects B):

1. `ThreadRef` is observed and within retention ⇒ else `THREAD_NOT_OBSERVED`.
2. B is an approved, enabled Router model for that client: `TryResolveModel` plus
   route/client eligibility ⇒ else `MODEL_NOT_APPROVED` or
   `MODEL_ROUTE_UNAVAILABLE`.
3. `expected_generation` matches ⇒ else `THREAD_SELECTION_CONFLICT` (§16).

Dynamic checks at request time (unchanged from today's path): capabilities
derived from the real request (`text`, `streaming`, `reasoning`, `tools`) must be
covered by the selected model's capability intersection, otherwise the request
fails closed with `MODEL_CAPABILITY_MISMATCH` / `unsupported_capability`.

**Decision (capability failure):** fail the request closed, **keep** the
selection (`ACTIVE` stays `ACTIVE`, `PENDING` stays `PENDING`), set
`last_failure_code` and `last_failure_at`, expose `degraded = true` in the read
projection, and require the user to switch or clear. The Router never silently
falls back to A and never picks a third model.

## 15. Reasoning effort policy

**Decision — `EFFORT_POLICY` = preserve the incoming Codex effort exactly.**

- The Router never rewrites `reasoning.effort` and never clamps it.
- If the selected model cannot serve the request's reasoning capability, the
  request fails closed (`MODEL_CAPABILITY_MISMATCH`). No silent downgrade.
- The V4 UI must state that "switch model" does not change Codex's reasoning
  effort, because changing effort requires a Codex-side control that does not
  exist in the reachable boundary (gate §7 and §15.11).
- An effort override would be a separate capability with its own gate.

## 16. Generation / CAS

- `ThreadSelectionGeneration` is per thread, monotonic (`uint64`), starts at 1,
  and increments on every selection-changing transition (set, claim, supersede,
  clear).
- It is **independent of** the global config generation
  (`PublishedRouterState.ConfigGeneration`), which keeps its existing meaning for
  config/policy/feature mutations. Sharing them would make a policy edit look
  like a thread-selection conflict.
- Every mutation carries `expected_generation`; a mismatch returns HTTP 409 with
  `control_thread_selection_conflict` — never last-write-wins.
- Reads expose the current generation so a client can always re-read and retry.

## 17. Thread reference handling

- External keys are `ThreadRef` (§5.3); the raw id is never an API key, never a
  log field, and never a UI string.
- The store keys internally by the canonical raw id (exact identity) and indexes
  `ThreadRef` → canonical id; both maps are in memory only.
- The hashing policy is fixed and documented so a future export or telemetry
  path cannot silently change it: SHA-256 over the canonical id, truncated to
  64 bits, lowercase hex.

## 18. Control Plane contract (design only)

Style: identical to LR-14P — loopback `127.0.0.1`, `Bearer` token plus the
`router:control-plane` scope through `ClientScopeRegistry`, `application/json`,
the existing `MaxControlPlaneMutationBytes` (64 KiB) body limit, the fixed error
allowlist, versioned payloads, and zero provider calls for any control action.

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/v1/router/control-plane/threads?limit=` | bounded observed-thread projection |
| `GET` | `/v1/router/control-plane/threads/{threadRef}/selection` | current selection state |
| `PUT` | `/v1/router/control-plane/threads/{threadRef}/selection` | set model (`schema_version`, `expected_generation`, `model`) |
| `DELETE` | `/v1/router/control-plane/threads/{threadRef}/selection` | clear (restore the Codex requested model), `expected_generation` in body |
| `POST` | `/v1/router/control-plane/threads/capture` | start a capture window |
| `GET` | `/v1/router/control-plane/threads/capture/{token}` | capture status |
| `DELETE` | `/v1/router/control-plane/threads/capture/{token}` | cancel capture |
| `GET` | `/v1/router/control-plane/thread-selection-feature` | read `thread_selection` feature state (also embedded in `/v1/router/control-plane/status`) |
| `PUT` | `/v1/router/control-plane/thread-selection-feature` | enable/disable the thread-selection capability (`schema_version`, `expected_generation`, `enabled`) |
| `DELETE` | `/v1/router/control-plane/threads/selections` | **explicit clear-all** of every selection + capture (separate action; see §18.2) |

Per-thread read projection: `thread_ref`, `client_id`, `first_seen`, `last_seen`,
`last_request_kind`, `last_requested_model`, `last_selected_model`,
`window_number` (nullable), `selection_state`, `selection_model`,
`selection_generation`, `selection_issued_at`, `selection_expires_at`,
`last_failure_code`, `degraded`.

New schemas, following the existing `local-router/schemas/control-plane-*.v1`
conventions: `control-plane-threads.v1.schema.json`,
`control-plane-thread-selection.v1.schema.json`,
`control-plane-thread-selection-mutation.v1.schema.json`,
`control-plane-thread-selection-mutation-result.v1.schema.json`,
`control-plane-thread-capture.v1.schema.json`,
`control-plane-thread-selection-feature.v1.schema.json`,
`control-plane-thread-selection-feature-mutation.v1.schema.json`,
`control-plane-thread-selection-clear-all.v1.schema.json`.

`limit` reuses the existing `ControlPlaneProjections.ResolveLimit` clamp.

### 18.1 `thread_selection` status projection

The status read (`GET /v1/router/control-plane/status`, plus the dedicated
feature read) exposes exactly:

```
thread_selection:
  configured_enabled      (from config)
  effective_enabled       (runtime, after publication)
  mutation_available      (config operator present and generation known)
  observed_thread_count
  active_selection_count
  pending_selection_count
  capture_open            (bool)
  snapshot_at             (ISO-8601)
```

Never exposed: raw thread ids, prompt/response/reasoning/tool content, raw
metadata JSON, or any header value.

### 18.2 Explicit "Clear All Thread Model Selections"

An independent, explicit operation — **not** part of Safe Restore (§26):

```
DELETE /v1/router/control-plane/threads/selections
body: { "schema_version": 1, "confirm": "clear_all_thread_model_selections" }
```

- explicit authenticated user action, confirmed in V4 ("清除全部会话模型覆盖");
- reuses the existing control-plane auth (`router:control-plane`, loopback,
  `CODEX_LOCAL_ROUTER_TOKEN`), body limit, and JSON/error conventions;
- clears **all** `PENDING`, all `ACTIVE`, and all open/`CAPTURED` captures;
- audit reason `explicit_clear_all`;
- zero provider calls;
- **does not** touch: CLI route, Desktop route, `local_router.enabled`, policy
  bodies, provider config/secrets, or `ConfigGeneration`.
- response: `schema_version`, `result = cleared`, `cleared_selection_count`,
  `cancelled_capture_count`, `snapshot_at`.

### 18.3 Feature enable / disable (explicit capability opt-in)

`local_router.thread_selection.enabled` ships **false** and is toggled only
through this authenticated, generation-aware control-plane mutation — never by
editing `router.config.json` by hand, never by the installer, never implicitly
when V4 opens.

```
PUT /v1/router/control-plane/thread-selection-feature
body: { "schema_version": 1, "expected_generation": <Router ConfigGeneration>, "enabled": true|false }
```

The mutation reuses — and must not duplicate — the existing LR-14P machinery:
`ConfigMutationGate`, the config load/validate/atomic-write path in
`LocalRouterConfigOperator`, the config-generation CAS (`409`
`control_generation_conflict` when stale), the same-state runtime publication
through `IRouterConfigPublicationSink` / `CurrentRouterState`, and the existing
single control-plane auth. Response carries the new `ConfigGeneration` plus the
published `thread_selection` projection.

**Enable semantics (`false → true`)** — capability only:

- no selection is created, no capture is created, no request model changes, and
  zero provider calls occur;
- `enabled = true` with **0 overrides must be 100 % routing-equivalent to the
  current Router behavior** (`request.Model` → `RouteResolver`).

**Disable semantics (`true → false`)** — after the config commit/publication:

- all `PENDING` and all `ACTIVE` selections are cleared and all captures are
  cancelled;
- audit reason `thread_selection_feature_disabled`;
- every later request resolves `requested_model` through the existing normal
  Route Resolver; no armed override may survive.

**Observable atomicity (runtime publication).** A live capability change is one
runtime publication: the durable config commit, the published
`PublishedRouterState` generation, and the runtime effective state of the single
thread-selection store all belong to one pair. Exactly one process-wide runtime
consistency boundary (`IRouterRuntimeConsistencyGate`) is composed and shared by
the runtime publication sink, the thread-selection store, and the combined
control-plane projections: the publication applies both owners inside ONE
exclusive section, every thread-selection operation enters that same boundary,
and `GET .../control-plane/status` / `GET .../thread-selection-feature` capture
the published state and the capability summary inside one shared section. An
observer can therefore only complete on the OLD pair or the NEW pair - never on
a new published config combined with an old capability state, or the reverse.
The linearization point of a publication is the release of that exclusive
section; when a mutation reports success, the durable commit, the published
generation, and the store's effective state are all already in place.

**Generation discipline:** enabling/disabling the capability uses the **Router
`ConfigGeneration`** (it is a global config mutation). Setting/clearing one
thread's selection uses the **`ThreadSelectionGeneration`** (§16). Neither
increments the other: a feature toggle never bumps any thread generation, and a
thread mutation never bumps `ConfigGeneration`.

## 19. Thread-reference validation for mutations

- Mutations accept **only** an observed `ThreadRef` — never a raw id, never a
  `session-id`.
- Unknown or evicted refs return HTTP 404 `control_thread_not_observed`, so a
  client cannot create state for arbitrary or guessed identifiers.
- An observed thread whose `LastSeen` is older than the entry idle TTL is treated
  as unknown.
- There is at most one selection entry per observed thread, so the mutation state
  surface is bounded by the registry cap (§6) and by §22.

## 20. Capture mode contract

| Field | Value |
|---|---|
| `capture_token` | 128-bit random, lowercase hex (32 chars); never derived from thread ids |
| `schema_version` | 1 |
| `created_at` / `expires_at` | default window 120 s (floor 30 s, ceiling 600 s) |
| `owner` | the authenticated control-plane client (`ClientId` resolved from scope) |
| `status` | `open` / `claimed` / `expired` / `cancelled` |
| claim rule | first `request_kind == "turn"` request with a canonical identity; single CAS claim that resolves **identity only** |
| captured projection | `thread_ref`, `last_seen`, `requested_model`, `effective_model`, `client_id`, `capture_status` |
| effects on routing | **none**: capture never creates `PENDING`/`ACTIVE`, never changes the captured turn's model or route, and issues 0 provider calls |
| captured retention | `CAPTURED` is retained for a short read TTL (default 300 s) so V4 can read the `ThreadRef` |
| conflicting activity | the loser is untouched (no mutation, served normally); a second distinct thread can never steal a claimed capture |
| cleanup | expired or cancelled tokens are dropped; at most one open capture per client, and a new capture cancels the previous token |

## 21. V4 contract

Extend the existing `NavRouter` page (`installer/ui/visual-console.xaml`) and the
`visual-router-runtime.ps1` projections. No redesign and no new page:

- New section "Observed Codex threads" with rows: `ThreadRef` (short), last seen,
  **Codex requested model**, **Router effective model**, selection-state badge
  (`NONE` / `PENDING` / `ACTIVE` / `EXPIRED` / `CLEARED` / `CONFLICT` /
  `DEGRADED`), and the last failure code.
- Controls: pick a thread → pick an approved model (reuse the existing
  `RouterModelCombo` source) → `切换此会话模型` (`PUT`) and
  `恢复 Codex 原模型` (`DELETE`).
- Feature status shown **separately** from the Router feature:
  `Router 功能：Enabled / Disabled` and
  `会话模型切换：已启用 / 已停用`, with dedicated buttons
  `启用会话模型切换` / `停用会话模型切换`
  (`PUT /v1/router/control-plane/thread-selection-feature`). These buttons must
  never be merged with the existing `启用 Router 功能` / `停用 Router 功能`
  controls.
- Readiness rule: the Observed Threads section (list, capture, set, clear) is
  operable **only** when Router feature = enabled **and** thread selection =
  enabled **and** the runtime control plane is reachable. Otherwise the section
  renders disabled with the corresponding reason.
- Capture wording: `识别当前 Codex 会话` (never "capture and switch"). On success:
  `已识别会话 <ThreadRef>。请选择目标模型并确认切换。` — the model picker and
  `切换此会话模型` remain a separate, explicit step.
- Clearing: `恢复此会话 Codex 请求模型` clears one thread; the independent
  `清除全部会话模型覆盖` performs §18.2 and **requires a confirmation dialog**.
- `Safe Restore Direct` keeps its existing LR-14 meaning and UI behavior
  unchanged (§26). It is not a thread-selection control.
- Copy rules (honesty): always show both truths, for example
  `Codex 请求模型：A` and `Router 当前生效模型：B`; never claim
  "Codex 当前模型已改变"; state that a Router restart, disable, or TTL expiry
  returns the thread to A.
- Refresh stays read-only: `GET /threads` plus `GET …/selection` add **0**
  provider calls and **0** mutations.
- Errors use the existing code → localized-message mapping
  (`Convert-RouterV4ControlCodeToUiCode`, `Convert-RouterV4UiErrorMessage`).

## 22. Native Desktop picker

`NATIVE_DESKTOP_PICKER_CUSTOM_ROUTER_MODELS = UNSUPPORTED` — unchanged. HS-1B
never injects, patches, or extends the official picker or `model/list`. The V4
selection is a Router-side routing decision, not a Codex model change.

## 23. Audit / observability

Extend, never fork, the existing safe records:

- `Router.Observability/SafeRequestRecord.cs` gains `ThreadRef`,
  `RequestedModel`, `SelectedModel`, `SelectionSource`, `OverrideGeneration`,
  and `RequestKind` — all bounded enums/strings, still with no prompt, response,
  reasoning, tool, or secret fields.
- `TraceEventKind` gains a route-selection event carrying the same fields.
- `DurableRequestLog` and the control-plane recent-request projection gain the
  same fields; `tests/fixtures/local-router/v1/observability/
  request-record.allowed-fields.json` is extended in the same commit (it is the
  allowlist contract, so the addition is explicit and reviewed).
- The raw `x-codex-turn-metadata` JSON is **never** logged; only the two
  extracted fields and the derived `ThreadRef` are.

## 24. Error contract (fixed allowlist)

| Code | HTTP | Meaning |
|---|---|---|
| `control_thread_not_observed` | 404 | ref unknown or evicted |
| `control_thread_selection_conflict` | 409 | `expected_generation` stale |
| `control_thread_selection_expired` | 409 | pending or active TTL elapsed |
| `control_thread_selection_disabled` | 503 | capability configured off (`thread_selection.enabled = false`); thread reads/mutations unavailable |
| `control_thread_selection_unavailable` | 503 | store or runtime unavailable (Router not serving, config operator absent) |
| `control_thread_selection_feature_update_failed` | 422 | feature enable/disable could not be applied |
| `control_thread_identity_mismatch` | trace only | `thread-id` ≠ metadata `thread_id`; request served normally |
| `control_thread_selection_invalid_request_kind` | trace only | missing/unknown `request_kind`; no consumption |
| `control_model_not_approved` | 422 | model not approved/enabled for the client |
| `control_model_route_unavailable` | 422 | no eligible route for that model |
| `control_model_capability_mismatch` | 422 (mutation) / `unsupported_capability` (request) | model cannot satisfy the required capability set |

Reused unchanged: `control_invalid_request`, `control_payload_too_large`,
`control_mutation_busy`, `control_generation_conflict` (config generation only),
`control_read_unavailable`, `control_read_degraded`, `scope_denied`. No raw
exception text ever reaches V4.

## 25. Failure semantics

- A failing or unhealthy selected-model provider returns the normal typed
  provider error. There is **no cross-model fallback**: the existing
  `FindSameModelAlternateRoutes` semantics stay unchanged (same-model alternates
  only, `FailoverPolicy.Enabled` still required), and cross-model fallback
  remains hard off.
- The selection stays `ACTIVE`; the UI shows the failure code and the user can
  clear or switch. No silent revert to A and no silent third model.
- Router disabled or process down ⇒ requests are not served at all (existing
  behavior); no thread state is fabricated anywhere else.

## 26. Route restore, clear-all, feature disable, restart

Three different lifecycles must never be conflated. The merged LR-14 contract is
normative: Safe Restore "only restores the Router-related CLI/Desktop routes. It
never deletes secrets, never deletes provider config, never disables the Router
feature, and never kills a Router process"
(`docs/LOCAL_ROUTER_V4_UI.md`, "Safe Restore Direct";
`Get-RouterV4SafeRestorePlan` in `installer/scripts/visual-router-runtime.ps1`
only emits `restore_desktop` / `disable_cli`).

### 26.1 Safe Restore Direct (LR-14 contract, unchanged by HS-1B)

| Safe Restore Direct | Behaviour |
|---|---|
| restores | CLI Router route and Desktop Router route only |
| `local_router.enabled` | **NOT** changed |
| `thread_selection.enabled` | **NOT** changed |
| thread model selections | **NOT** cleared (no implicit clear) |
| captures | **NOT** cancelled |
| Router process | **NOT** stopped or killed |
| secrets / provider config | **NOT** removed |
| policy / unrelated Router feature state | **NOT** mutated |
| control-plane calls made by Safe Restore | none of the thread-selection endpoints |

After a Safe Restore the Router may simply stop receiving that thread's traffic;
the selection then ages out only through a defined condition — idle TTL
(`active_idle_ttl_ms`), Router process restart, explicit clear-one/clear-all, or
the capability's own disable path. HS-1B adds no route-restore responsibility.

### 26.2 Explicit Clear All Thread Model Selections (§18.2)

A separate, confirmed user action that clears every selection (all `PENDING`,
all `ACTIVE`) and cancels captures, audited as `explicit_clear_all`. It touches
neither the CLI/Desktop routes nor `local_router.enabled` nor policy nor
provider config.

### 26.3 Capability disable and overall Router feature disable

| Event | Thread selection state | Rationale |
|---|---|---|
| `thread_selection.enabled = true → false` (§18.3) | **cleared for all threads** + captures cancelled, audited `thread_selection_feature_disabled` | the capability itself was switched off; no armed override may survive |
| `local_router.enabled = false` (existing overall feature mutation) | **cleared for all threads** + captures cancelled, audited | the user explicitly stopped the whole Router feature; leaving armed overrides would surprise them on re-enable |
| `thread_selection.enabled = false → true` | nothing cleared, nothing created; 0 selections + 0 overrides is routing-equivalent to today | enabling is a capability grant only |
| Router process restart | **cleared** (memory only) | no durable persistence by design; the Codex requested model applies again |
| Selection read after any of the above | `NONE` plus a `last_cleared_reason` audit field | explainable, never silent |

**Summary matrix**

| Action | CLI/Desktop route | `local_router.enabled` | `thread_selection.enabled` | thread selections |
|---|---|---|---|---|
| Safe Restore Direct | restored | unchanged | unchanged | **unchanged** |
| Clear All Thread Model Selections | unchanged | unchanged | unchanged | cleared |
| Disable thread-selection capability | unchanged | unchanged | false | cleared |
| Disable overall Router feature | unchanged | false | unchanged | cleared |

## 27. Bounds / cleanup / DoS

- Registry caps and TTLs per §6; selection entries are bounded by the registry
  cap.
- Mutation bodies are capped by the existing 64 KiB ceiling; thread ids are
  capped at 64 bytes; capture tokens are bounded and single-open per client.
- Capture state is doubly bounded: a hard TTL per window (`OPEN`) and a shorter
  retention TTL per claimed result (`CAPTURED`), plus a hard count ceiling for
  retained capture entries derived from the registry cap. Expired entries are
  removed at read/claim/mutation time, and under count pressure the oldest
  `CAPTURED` result is evicted while the live `OPEN` window is never evicted.
- Malformed or oversized identity material never allocates store state.
- Eviction is deterministic last-seen LRU; the evicted-entry count is a safe,
  content-free counter exposed in the read projection.
- No background timers are needed: TTLs are evaluated lazily at read and claim
  time, so an idle Router performs no work.

## 28. Security / threat model

| Threat | Mitigation |
|---|---|
| spoofed `thread-id` | identity is only accepted on the authenticated loopback surface; a spoofed id can at worst affect that same client's own traffic, and a mutation still requires an observed ref plus an explicit user action |
| `thread-id` vs metadata mismatch | fail closed (§5.2): no observation, no consumption |
| stale V4 generation | `expected_generation` CAS ⇒ 409 |
| auxiliary request consuming pending | `request_kind == "turn"` gate (§12) |
| cross-thread leakage | per-thread key plus generation; isolation covered by tests (§31) |
| malformed metadata | bounded parse; no identity on failure |
| replay of a mutation | generation CAS makes replays no-ops or 409 |
| memory exhaustion | registry caps, TTLs, LRU eviction, bounded body and header size |
| Router restart mid-session | state cleared; documented and surfaced in the UI |
| multiple V4 clients | CAS with a single writer per transition |
| secret/content leakage | the store has no content fields by construction; the raw thread id never leaves memory; the control plane exposes metadata only |

Inherited and unchanged: loopback-only bind, bearer token from an environment
reference, the single `router:control-plane` scope, no upstream provider key at
the client boundary, no `auth.json`, no prompt storage, no raw exceptions, no
arbitrary endpoint, and no Codex database access.

## 29. Rollback

- Kill switch: `local_router.thread_selection.enabled`, default **false**, added
  as an additive optional config block validated by the existing config loader.
  When false the store is never consulted and the thread-selection endpoints
  return `control_thread_selection_disabled`.
- **Formal enable path (no hand-editing):** the capability is switched on and off
  only through `PUT /v1/router/control-plane/thread-selection-feature` (§18.3),
  reusing `ConfigMutationGate`, the atomic config write, the config-generation
  CAS, and the same-state publication. The installer never sets it to `true` and
  V4 never auto-enables it on open.
- With thread selection disabled or removed, every request resolves exactly as it
  does today (`request.Model` → `RouteResolver`), so rollback requires **no**
  Codex DB, Desktop, or `config.toml` restore.
- Disabling the capability (or the overall Router feature) clears all selections
  and cancels captures; "clear all" is also available as its own explicit,
  confirmed action (§18.2, §26.2).

## 30. Test plan

Unit and component tests in a new `local-router/tests/Router.ThreadSelection.Tests/`:

1. Requested A → set B → the next eligible turn resolves B.
2. The second and third ordinary turns on the same thread still resolve B
   (sticky, not one-shot).
3. Clear → the next turn resolves A again.
4. T1 → B and T2 → C produce no cross contamination.
5. `PENDING` is consumed only by `request_kind == "turn"`.
6. An auxiliary request (title, summary, probe) does not consume.
7. Missing or unknown `request_kind` does not consume and does not mutate.
8. `thread-id` vs metadata mismatch: no consumption, trace code recorded, and the
   request is still served with the requested model.
9. CAS conflict: stale `expected_generation` ⇒ 409 and unchanged state.
10. Unapproved or disabled model ⇒ mutation rejected with
    `control_model_not_approved`.
11. Selected model incompatible with the real request ⇒ fail closed, state kept,
    degraded flag set.
12. An in-flight turn keeps its resolved route while a switch commits.
13. Pending TTL expiry ⇒ `EXPIRED`, no consumption, requested model used.
14. Active lifetime per §10 (process lifetime plus idle TTL).
15. Router restart ⇒ all selections `NONE`.
16. Feature disable ⇒ clear-all with an audited reason.
17. Registry bounds: cap, LRU eviction, oversized and malformed ids rejected.
18. Capture: single claim under concurrency, expiry, cancel, and one open capture
    per client.

Integration tests in `local-router/tests/Router.Ingress.Tests/` and
`local-router/tests/Router.Execution.Tests/`:

19. Control-plane endpoints enforce the scope, the body limit, the fixed errors,
    and never issue a provider call or pollute the durable request log
    (`RequestPipeline.Record` untouched).
20. Read-only refresh performs zero mutations and zero provider calls.
21. Malformed control-plane bodies never create state.

Repository validators (PowerShell, CI-safe, static or fake-only):

22. New `tests/validate-local-router-thread-selection.ps1`: schema presence,
    endpoint registration on the single scope, no second registry/resolver/store,
    no content fields in payloads, error allowlist, and no forbidden destructive
    Git behaviour.
23. Extend `tests/validate-local-router-lr14p-control-plane.ps1` expectations so
    the new endpoints stay on the single scope and remain out of
    `RequestPipeline.Record`.

Lifecycle-separation tests (the three lifecycles of §26 must never be
conflated):

24. **TEST A — Safe Restore Direct is route-only.** With `T1 ACTIVE = B`:
    execute V4 Safe Restore Direct ⇒ CLI/Desktop routes restored, and the
    thread-selection store is **not** mutated by Safe Restore (no capability
    disable call, no clear-all call). The selection later ages out only by idle
    TTL, process restart, explicit clear, or capability/feature disable.
25. **TEST B — explicit clear-all.** `DELETE …/threads/selections` clears all
    `PENDING`/`ACTIVE` selections and captures, audits `explicit_clear_all`, and
    leaves routes, `local_router.enabled`, `thread_selection.enabled`, policy,
    and provider config untouched.
26. **TEST C — capability disable.** `PUT …/thread-selection-feature
    enabled=false` clears all selections and captures and audits
    `thread_selection_feature_disabled`.
27. A single test asserts A/B/C are mutually exclusive: none of them performs
    another's side effects.

Capture tests (identity discovery only):

28. Capture target thread T1; the capture turn requests A and the fake provider
    receives **A** (no model change on the capture turn).
29. Capture result exposes `ThreadRef(T1)` and the thread's selection state is
    still `NONE`; `CAPTURE_CREATES_PENDING` and `CAPTURE_CREATES_ACTIVE` are both
    asserted false.
30. Only after `PUT T1 selection=B` does the **next** eligible turn use B — i.e.
    the capture turn is not the switch turn.
31. Capture does not create a provider call and does not change routing
    (`CAPTURE_PROVIDER_CALLS = 0`).

Feature-enable tests:

32. Default config ⇒ `thread_selection.enabled = false`; `GET /threads` returns
    the typed disabled state (`control_thread_selection_disabled`), and no store
    state exists.
33. `PUT …/thread-selection-feature enabled=true` with
    `expected_generation = G1` ⇒ `ConfigGeneration = G2`, effective enabled, **0
    provider calls**; a refresh performs **0** mutations; a subsequent
    `PUT …/threads/{ref}/selection` now succeeds.
34. Stale `expected_generation` ⇒ 409, no retry, no overwrite.
35. Disable `G2 → G3` ⇒ selections/captures cleared; the next normal request uses
    the Codex requested model.
36. Generation separation: the feature toggle never increments any
    `ThreadSelectionGeneration`, and a thread set/clear never increments
    `ConfigGeneration`.
37. Enable with 0 overrides is routing-equivalent: a request before and after
    enabling resolves the identical route/model.

Identity-fallback tests (truth table §5.2):

38. Cases 4, 5, and 6 each fail the identity closed — a malformed or mismatching
    presented source never falls back to the other source.
39. Cases 7, 8, and 9 produce no identity, no observation, and no consumption.
40. Cases 1, 2, and 3 accept the identity and observe the thread.

Request-kind tests:

41. Only `request_kind == "turn"` applies a selection; non-`turn` and
    missing/unknown kinds always use the Codex requested model (never B).

## 31. Proposed implementation files (planning only, real paths)

EXISTS — reuse unchanged:

- `local-router/src/Router.Routing/{RouteResolver.cs,RouteRequest.cs}`
- `local-router/src/Router.Registries/{RouterRegistrySnapshot.cs,ModelLookupResult.cs}`
- `local-router/src/Router.Execution/{RouterExecutionResponsesService.cs,RouterExecutionPolicySource.cs}`
- `local-router/src/Router.Ingress/{ResponsesIngress.cs,ClientScopeRegistry.cs}`
- `local-router/src/Router.Configuration/CurrentRouterState.cs`

EXTEND:

- `local-router/src/Router.Core/Context/RequestContext.cs` (thread identity)
- `local-router/src/Router.Core/Errors/{RouterErrorCode.cs,ControlPlaneErrors.cs}`
- `local-router/src/Router.Ingress/Handlers/{ResponsesHandler.cs,ControlPlaneHandlers.cs}`
- `local-router/src/Router.Ingress/{ControlPlaneRuntimeServices.cs,IngressServices.cs}`
- `local-router/src/Router.Ingress/ControlPlane/{ControlPlanePayloads.cs,ControlPlaneProjections.cs}`
- `local-router/src/Router.Execution/RouterExecutionResponsesService.cs`
- `local-router/src/Router.Observability/{SafeRequestRecord.cs,Trace.cs,DurableRequestLog.cs}`
- `local-router/src/Router.Host/RouterHostBootstrap.cs`
- `local-router/config/router.defaults.json`, `local-router/schemas/router-config.v1.schema.json`
- `local-router/schemas/control-plane-status.v1.schema.json` (supported-contract list)
- `installer/scripts/visual-router-runtime.ps1`, `installer/ui/visual-console.xaml`
- `tests/fixtures/local-router/v1/observability/request-record.allowed-fields.json`

NEW:

- `local-router/src/Router.ThreadSelection/` project with `CanonicalThreadId.cs`,
  `ThreadRef.cs`, `ObservedThreadRegistry.cs`, `ThreadSelectionState.cs`,
  `ThreadSelectionStore.cs`, `ThreadCaptureStore.cs`, `ThreadSelectionErrors.cs`,
  `ThreadSelectionOptions.cs`
- `local-router/schemas/control-plane-threads.v1.schema.json`,
  `control-plane-thread-selection.v1.schema.json`,
  `control-plane-thread-selection-mutation.v1.schema.json`,
  `control-plane-thread-selection-mutation-result.v1.schema.json`,
  `control-plane-thread-capture.v1.schema.json`
- `local-router/tests/Router.ThreadSelection.Tests/`
- `tests/validate-local-router-thread-selection.ps1`
- `local-router/tests/Router.Ingress.Tests/ControlPlaneThreadSelectionTests.cs`

## 32. Proposed PR boundary

One independent capability PR, "HS-1B: thread-scoped Router model selection",
containing exactly: thread observation, thread-scoped model selection,
control-plane endpoints and schemas, the minimal V4 control section, audit
fields, tests, and docs.

Explicitly excluded: LR-15 hardening/packaging/release work, UI redesign,
lifecycle Start/Stop ownership, circuit-breaker configuration, provider
expansion, catalog expansion, the `mm_openai_api` catalog gap, and any
Codex/Desktop/DB/config change.

## 33. Comparison with the app-server path

| | App-server path | HS-1B Router path |
|---|---|---|
| Model change mechanism | official `turn/start` and `thread/resume` model fields | Router-effective model resolved per request |
| Reachability on the Windows Desktop | **none** — stdio app-server owned by the Desktop, no listening socket, daemon lifecycle Unix-only (gate §15.7) | always available: the Router is already in the request path |
| Loaded-thread behaviour | `thread/resume(model=…)` ignored while the thread is loaded (gate §15.3) | not applicable: resolution is per request |
| Codex-side truth | Codex would change its own thread settings | Codex keeps requesting A while the Router resolves B — dual truth must be shown honestly |
| State to manage | none (Codex owns it) | per-thread selection, generation, TTLs — in memory only |
| Failure mode | none reachable today | the Router must fail closed and never silently revert |

The app-server path stays documented as **re-openable** if Codex exposes a live
control boundary on Windows, or a sanctioned way to unregister and re-register a
live Desktop thread. Until then the Router path is the only mechanism that works
with the Desktop as shipped.

## 34. Technology intake (no duplicate subsystems)

| Capability | Reuse | Extend | New |
|---|---|---|---|
| Model registry and approved-model gating | `RouterRegistrySnapshot.TryResolveModel` | — | — |
| Route resolution | `RouteResolver` | — | — |
| Execution path | `RouterExecutionResponsesService` | selection lookup before `RouteRequest.Create` | — |
| Control plane | `ControlPlaneHandlers` and the payload/schema conventions | new endpoints and payloads | — |
| Authentication | `ClientScopeRegistry`, `AuthenticationMiddleware` | — | — |
| Observability | `SafeRequestRecord`, `Trace`, `DurableRequestLog` | six selection/audit fields | — |
| Live state publication | the `CurrentRouterState` pattern | — | `ThreadSelectionStore` (a different, non-config state domain) |
| V4 | `visual-router-runtime.ps1` projections and runspace workers | new section and calls | — |
| Metering, health, circuit breaker | unchanged | — | — |

## 35. Roadmap accounting

The formal Local Router roadmap remains **17 / 18**. HS-1B is an independent
capability extension; it does not renumber, replace, or expand LR-15, and this
document does not change the CI gate.

## 36. Open questions

1. Should `ACTIVE` also be cleared when the user's Codex client restarts? The
   Router sees `installation_id` in metadata, but treating it as a lifecycle
   signal is not yet justified by evidence.
2. Is `window_number` stable enough to display? (Currently treated as advisory.)
3. Should the V4 list be filterable per `ClientId` when both Desktop and CLI
   Router clients are configured? (Design default: show `client_id` per row.)
4. Is capture mode needed in v1 at all if Option A covers the common case? (Kept
   as the fallback per §7.)
5. Should `active_idle_ttl_ms` be mutable through the control plane, or only
   through the config file? (Design default: config file only, to keep thread
   selection out of the config-mutation gate.)

## 37. Design blocker closure and GO / NO-GO

### 37.1 Blocker closure checklist

| Blocker | Status | Closed by |
|---|---|---|
| Safe Restore contract conflict | **RESOLVED** | §26.1 (route-only, inherits LR-14), §18.2 (independent clear-all), §26.2/§26.3 matrix, §30 tests 24–27 |
| Capture mode had no model semantics | **RESOLVED** | §7.2/§7.3 (identity discovery only), §9 (only an explicit set creates `PENDING`), §18 capture endpoints, §30 tests 28–31 |
| Thread-selection feature had no enable path | **RESOLVED** | §18.3 (`PUT …/thread-selection-feature`), §18.1 status projection, §21 V4 controls, §29, §30 tests 32–37 |
| Identity rule ambiguity | **RESOLVED** | §5.2 CASE 1–9 truth table, §30 tests 38–40 |

### 37.2 Verdict

**HS-1B: GO**
**Implementation Ready: YES**

Implementation may proceed as the single capability PR of §32. This document
itself still changes no production behavior.

### 37.3 Mandatory invariants (non-negotiable during implementation)

1. Implementation happens only as the single capability PR of §32.
2. `local_router.thread_selection.enabled` defaults to **false** (kill switch) and
   ships disabled, with only the authenticated generation-aware enable path of
   §18.3 able to turn it on.
3. The V4 dual-truth copy of §21 ships before the feature is advertised.
4. Request truth (`requested_model`, `selected_model`, `selection_source`,
   `override_generation`) is part of the audit contract from the first commit.
5. Cross-model automatic failover stays hard off, and an explicit user selection
   is never classified as failover.
6. No durable persistence, no Codex DB/config/Desktop change, and no picker
   injection.
7. The Safe Restore Direct contract is unchanged and never owns the
   thread-selection lifecycle (no capability disable, no clear-all, no process
   stop, no secret/provider removal).
8. Capture is identity discovery only and never changes routing, never creates
   `PENDING`/`ACTIVE`, and never issues a provider call.
9. The thread-selection capability has an explicit authenticated,
   generation-aware enable/disable path using the Router `ConfigGeneration`.
10. Presented malformed identity metadata never falls back to another identity
    source (CASE 5 and CASE 6 of §5.2 fail closed).
11. Only `request_kind == "turn"` can use or activate a thread model selection;
    every auxiliary request uses the Codex requested model.

Future reopen trigger for the app-server path: a Codex build that exposes an
attachable app-server control boundary on Windows, or a sanctioned way to
unsubscribe and re-register a live Desktop thread. If that lands before HS-1B is
implemented, re-run the Final Desktop Closure Gate before choosing the
implementation path.
