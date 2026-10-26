# HS-1C — Quota-Exhaustion Sticky Failover (Router third-party providers)

Status: **DRAFT PR on the current `main` baseline — CI and independent review required before merge.**

Base: `main` (HS-1B thread-scoped model selection slice 1, merged via PR #89). Ported from Draft PR #88 (`feat/hs1c-quota-exhaustion-sticky-failover`, whose base was the HS-1B branch); #88 itself is left unchanged.

Scope: roadmap V1-10 and the Router-side part of V1-12; product goals G-2…G-6 **for Router-managed third-party provider routes only**. This is **not** ChatGPT subscription quota switching (V1-11).

## Goal

Keep the current Router-effective model until the provider gives explicit quota/credit exhaustion evidence. Only then walk the selected route's explicit `fallback_route_ids`. The first successful fallback becomes sticky for that thread.

This is not dynamic routing, load balancing, price routing, latency routing, or generic cross-model failover.

## Normative behavior

1. Normal success, ordinary 429, timeout, 5xx, slow response, price change, or another model being better/cheaper never causes a cross-model switch.
2. Only `quota_exhausted` or `credit_exhausted` may enter HS-1C.
3. Candidates come only from the explicitly configured `fallback_route_ids` of the route that was exhausted. Known EXHAUSTED fallback routes are skipped; last-known AVAILABLE routes are tried before UNKNOWN routes; config order is the tie-breaker.
4. Every candidate still passes the existing Route Resolver authorization (client allowlist), enabled-state, protocol, capability, health, and explicit-route gates. A route the client is not approved for, or a disabled route, is never attempted.
5. The successful candidate becomes ACTIVE sticky for the current thread.
6. Recovery of the old model never auto-switches the thread back. The user may manually select it.
7. A successful manual retry marks that route AVAILABLE again. A later exhaustion automatically re-arms HS-1C.
8. **All candidates unavailable (G-6):** each fallback is attempted at most once per request (no recursion, no loop). When none succeeds — exhausted, ineligible, unapproved, or failed — the request stops with `quota_fallbacks_exhausted` ("The model quota is exhausted and no approved fallback model is available."). No sticky state changes. A later turn skips the known-exhausted fallbacks, so it is bounded to the current model's single attempt.

## Manual authority

Manual selection always wins. The request captures the thread selection generation at start. Automatic sticky mutation uses generation CAS. Any later manual selection increments the generation, so a stale automatic write is rejected.

## Trigger classification

- HTTP 429 by itself is never quota exhaustion.
- OpenAI API: allowlisted quota/spend codes or `type=insufficient_quota` → `quota_exhausted`; `credit_balance_exhausted` → `credit_exhausted`.
- HTTP 402 (MiMo, DeepSeek insufficient balance, OpenRouter insufficient credits) → `credit_exhausted`.
- MiMo HTTP 429 remains `rate_limited` because it is ambiguous.
- Model Studio: HTTP 403 + `AllocationQuota.FreeTierOnly` → `quota_exhausted`; ordinary 429/throttling stays `rate_limited`.
- Unknown or malformed provider payloads fail closed to the existing status mapping.

Provider error-body inspection is capped at 16 KiB and only runs for status/provider pairs capable of establishing quota evidence (402 needs no body). Raw provider error text is never persisted or surfaced.

Where it runs: the #88 classifier is relocated unchanged in logic to `Router.Execution` (`QuotaExhaustionClassifier`). While HS-1C is enabled, the execution service gives each attempt a `QuotaEvidenceTransport` decorator that reads the bounded prefix under the attempt's own timeout boundaries and hands the provider adapter an equivalent response; the adapter's own status mapping is unchanged, and explicit evidence then replaces that attempt's `rate_limited` / `provider_4xx` error. No file under the protected `local-router/src/Router.ProviderAdapters.*` surface is modified (unlike #88, which changed the shared adapter base and adapter abstractions).

## Feature gate and default-off behavior

`local_router.thread_selection.quota_failover_enabled` defaults to `false`, and `thread_selection.enabled` must be `true` before it can be `true` (config validation rejects otherwise). LR-11 generic `AllowCrossModelFallback` remains hard OFF; HS-1C is a separate quota-only path.

With the gate off the Router behaves exactly as before HS-1C: no decorator is created, so no error body is read and no quota code exists (an exhausted-quota 429 stays `rate_limited`, a 402 stays `provider_4xx`), the quota tracker is not updated, and no automatic selection is written.

`quota_failover_enabled` is accepted by the .NET configuration schema, merger and validator, and by the installer Router bootstrap (`installer/scripts/router-codex-cli.ps1 -Action Initialize`, slice HS1C-INSTALLER-CONFIG-COMPAT). It is deliberately **not** added to `router.defaults.json`, so an absent setting means off.

How to turn it on: write it explicitly in the Router user config (`%CODEX_HOME%/multimodel-manager/local-router/router.config.json`) together with `thread_selection.enabled`:

```json
"local_router": { "thread_selection": { "enabled": true, "quota_failover_enabled": true } }
```

Installer rules (mirroring `RouterConfigValidator`):

- absent → off; Initialize never adds the field and never turns it on;
- explicit `false` or `true` is preserved exactly across Initialize and re-Initialize;
- only a JSON boolean is accepted: strings (`"true"`), numbers, `null`, arrays and objects are rejected;
- `true` requires `thread_selection.enabled=true`;
- any other unknown `thread_selection` field is still rejected;
- a rejected config is refused before any write: its bytes stay unchanged and no backup is created.

Enabling it does not create, approve or select any fallback model: candidates still come only from each route's explicit `fallback_route_ids`, subject to the client allowlist and the Route Resolver.

## Health / breaker separation

Quota exhaustion is account-capacity state, not endpoint health. It is recorded only in `QuotaAvailabilityTracker` (in memory, never probes providers) and does not degrade passive health or increment the circuit breaker. This preserves the user's ability to manually retry a recovered model immediately.

## Output boundary

Transparent failover is pre-output only. A quota failure that arrives after a stream has started producing output is never replayed onto another model; the existing terminal-stream boundary reports it.

## ChatGPT account boundary

The signed-in ChatGPT/OpenAI account provider remains DIRECT_ONLY. Local Router does not read `auth.json` or proxy ChatGPT account credentials. HS-1C covers Router-managed provider/API routes only (`mm_openai_api`, `mm_mimo`, `mm_modelstudio`, `deepseek`, and eligible `mm_openrouter` routes). `mm_openai_api` is a pay-as-you-go API key route and does not represent ChatGPT subscription quota.

"ChatGPT subscription quota exhausted → Router model" (V1-11) needs a separate, approved design; HS-1C must not infer that state or weaken the credential boundary.

## Known limits (not addressed in this slice)

- There is no UI switch or setup wizard for HS-1C; it is enabled only by editing the Router user config as shown above.

- The Ingress HTTP status mapper has no entry for `quota_exhausted`, `credit_exhausted` or `quota_fallbacks_exhausted`, so these reach the client as HTTP 500 with the explicit error code in the body. Choosing a dedicated status is an Ingress change outside this slice.
- Sticky state is HS-1B in-memory state: it is lost on Router restart, and an ACTIVE selection still expires after the HS-1B active idle TTL. Expiry is not triggered by quota recovery.
- A fallback stream is made sticky when it is accepted, before its terminal event.
- No switch history is recorded (V1-13).

## Acceptance gate

Covered by `Hs1cQuotaFailoverE2ETests`, `Hs1cQuotaFailoverAcceptanceTests`, `QuotaExhaustionClassifierTests` and `ThreadSelectionStoreTests`: explicit exhaustion switches; ordinary 429, 5xx and timeout never switch; single fallback success; multi-candidate exhaustion; sticky success; no automatic switch-back; manual recovery; manual generation wins; re-arm after a later exhaustion; known-exhausted skip; unapproved and disabled routes never become candidates; all fallbacks unavailable → bounded `quota_fallbacks_exhausted`; no replay after streamed output; default-off keeps the pre-HS-1C mapping; quota does not poison health/breaker; no raw provider content. All tests use loopback fake providers only — no live provider calls or paid inference.

## Merge boundary

Independent Draft PR against `main`. No production-ready claim is valid until build, tests, regressions and the Windows Development Gate are green and the owner approves the merge.
