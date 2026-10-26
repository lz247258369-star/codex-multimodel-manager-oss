# Current-Session Model Hot Switch — Feasibility Gate

Status: **RESEARCH ONLY. No production behavior change.**

Formal LR roadmap: **17 / 18** (unchanged). This gate is **not** LR-15 and does
not modify the LR-15 PR boundary ("Hardening/packaging/release evidence only;
feature expansion requires new roadmap").

Gate date: 2026-09-14 · Baseline `main`: `e3d60a8eeffe0e4a74bc899a93b97aaff222dc0e`

## 中文摘要

结论 **VERDICT C —— SUPPORTED_APP_SERVER_PATH_AVAILABLE**。

- Codex 官方 app-server 协议（`turn/start`）**原生支持**同一 thread 的
  **下一 turn 指定不同 model 与 reasoning effort**，并且 **provider 身份可以保持
  `mm_local_router` 不变**。已用隔离 `CODEX_HOME` + 本地 loopback fake Responses
  provider 在三个真实 Codex 版本（0.149.1 / 0.153.4 / 0.154.0）上端到端验证：
  model 改变、effort 改变、thread 不变、历史继续、多 thread 互不串号。
- 原生 model picker（Desktop 与 CLI `/model`）**只列内置 catalog 模型**，
  不会列出 Router 自定义模型；CLI picker 还会提示 "Access legacy models by
  running `codex -m <model_name>` or in your config.toml"。
- 因此：**Desktop 原生 picker 无法直接热切换 Router 模型**；但 **V4 Manager 可以通过
  官方 app-server 控制边界，对既有 thread 的下一 turn 指定 model**。
- 不需要改 SQLite、不需要 patch 二进制、不需要重启、不需要新建 conversation、
  不需要丢弃历史。Router 侧 override 也有可行的 thread 身份键（见 §9），但优先级低于
  官方 app-server 路径。

## 0. Gate verdict block

| Item | Result |
|---|---|
| main HEAD | `e3d60a8eeffe0e4a74bc899a93b97aaff222dc0e` |
| Codex CLI version (gate start) | `codex-cli 0.149.1` (npm global) |
| Codex CLI version (gate end) | `codex-cli 0.154.0` — see §13 incident log |
| Codex Desktop version | `OpenAI.Codex` MSIX `26.903.9818.0`; bundled `codex.exe` = `codex-cli 0.153.4` |
| CLI same-session `/model` | **SUPPORTED** (with the limits in §7) |
| Desktop native picker custom model | **UNSUPPORTED** |
| Desktop same-thread model mutation | **SUPPORTED (protocol) / NOT TESTED (live Desktop UI)** |
| App-server supported path | **YES** |
| Router thread-scoped override feasible | **YES** (identity evidence in §9) |
| Requires SQLite edit | **MUST NO** — not used, not needed |
| Requires official Codex patch | **MUST NO** — not used, not needed |
| Requires restart | **NO** (app-server path) |
| Requires new conversation | **NO** (app-server path) |
| Context continuity proven | **YES** |
| Provider identity can remain `mm_local_router` | **YES** |
| Two concurrent threads isolated | **YES** |
| Reasoning effort switching | **YES** |
| Resume/history regression | **PASS** |
| Paid provider calls | **0** |
| Real user secret used | **NO** |
| Production files changed | **NO** |
| Verdict | **C — SUPPORTED_APP_SERVER_PATH_AVAILABLE** |
| Recommended new roadmap slice | **HS-1** (capability extension, not LR-15) |

## 1. Scope of this gate

In scope: reading, throw-away experiments, temporary loopback fake provider,
documentation.

Out of scope and **not performed**: local-router production code, V4 production
code, installer scripts, model catalog edits, Codex config writes of the user's
real `CODEX_HOME`, `state_5.sqlite` / `threads.model` edits, rollout session
JSON edits, Desktop binary/Electron/JS bundle patching, DLL injection, memory
patching, kill-and-restart model switching, new-conversation model switching.

## 2. Baseline verification

```
git fetch origin --prune      -> origin/main = e3d60a8
git checkout main             -> ok
git pull --ff-only origin main-> fast-forward
git status --short            -> (clean)
git rev-parse HEAD            -> e3d60a8eeffe0e4a74bc899a93b97aaff222dc0e
```

## 3. Environment record

| Fact | Value |
|---|---|
| `codex --version` (start) | `codex-cli 0.149.1` |
| `where.exe codex` | `%USERPROFILE%\AppData\Roaming\npm\codex(.cmd)` (npm shim, `@openai/codex`) |
| Desktop Codex | MSIX `OpenAI.Codex` `26.903.9818.0`, executable `ChatGPT.exe` |
| Desktop-bundled CLI | `%LOCALAPPDATA%\OpenAI\Codex\bin\7ac07f4ce733f89a\codex.exe` = `codex-cli 0.153.4` |
| Desktop app-server process | `codex.exe` running as the local app-server (PID observed) |
| PowerShell | `7.6.6` |
| .NET | runtime `Microsoft.NETCore.App 9.0.7`, `Microsoft.WindowsDesktop.App 9.0.7`; **no .NET SDK installed** |

## 4. Roadmap boundary confirmation

`docs/LOCAL_ROUTER_RUNTIME_ROADMAP.md`, LR-15 card:

> **PR Boundary** | Hardening/packaging/release evidence only; feature expansion requires new roadmap.

LR-13 also states existing-thread hot-switching as out of scope
("`Patch official Desktop, injecting official model picker, hot-switching
existing thread`"), and the LR-13 DoD requires "full restart/new thread".

Consequences recorded by this gate:

- This gate is **not** LR-15 implementation.
- Formal roadmap stays **17 / 18**.
- Hot switch, if implemented later, is a **new capability extension (HS-1)**.

## 5. LR-12 / LR-13 / LR-14 capability re-verification

Re-run of the repository's own fixture
(`tests/fixtures/local-router/codex-cli/run-codex-compat.ps1`) on the gate
machine produced:

```
CODEX LOOPBACK COMPAT = RUN
CODEX VERSION = codex-cli 0.149.1
LOOPBACK REQUESTS = 6
POST /v1/responses = YES
AUTHORIZATION LOCAL TOKEN = YES
MODEL = qwen3-coder-plus
LIVE PROVIDER = NO
CODEX LOOPBACK COMPAT = PASS
```

| Capability | Status after this gate |
|---|---|
| CLI custom `model_provider`, `wire_api="responses"`, loopback `base_url`, `env_key`, `requires_openai_auth=false`, `-m` | VERIFIED (unchanged) |
| CLI `/model` inside a running session | VERIFIED to exist and to change the in-session model; **catalog-only** (§7) |
| CLI `/model` selects a custom Router model ID | UNSUPPORTED |
| Desktop reads custom provider config and reaches a loopback Responses endpoint | NOT VERIFIED on the live Desktop (not installed as needed in LR-13; installed now but live-thread mutation is prohibited by this gate) |
| Desktop native picker lists custom Router models | UNSUPPORTED (evidence §8) |
| Existing-thread hot switch | **now SUPPORTED via official app-server protocol** (§6) — supersedes the earlier "not supported by design" statement for the *Manager* boundary |

## 6. Evidence A — official app-server per-turn model override

### 6.1 Protocol source (authoritative, generated from the installed binary)

`codex app-server generate-json-schema` (official command) emits the current
protocol, including:

`TurnStartParams` (v2) fields:

```
threadId : string                (required)
input    : UserInput[]           (required)
model    : string|null  -> "Override the model for this turn and subsequent turns."
effort   : ReasoningEffort|null -> "Override the reasoning effort for this turn and subsequent turns."
approvalPolicy, sandboxPolicy, cwd, serviceTier, summary, personality, ...
```

Request methods present in the generated schema include
`thread/start`, `thread/resume`, `thread/read`, `thread/fork`, `turn/start`,
`turn/steer`, `turn/interrupt`, `model/list`, `model/rerouted`,
`config/read`, `config/batchWrite`.

`ThreadSettings` (returned by `thread/start`, `thread/resume`) carries
**`model` and `modelProvider` as separate fields**, which is exactly the
separation this gate needs: provider identity can stay fixed while the model
changes.

### 6.2 Experiment design

- Throw-away `CODEX_HOME` in `%TEMP%`, never the user's `~/.codex`.
- Local loopback fake Responses provider (`127.0.0.1`, ephemeral port) that
  records per request: `model`, `reasoning.effort`, input item count,
  continuation fields, auth match, and `x-codex-*` identity headers.
- Two synthetic model IDs `hot-alpha` / `hot-beta` on a single custom provider
  `mm_local_router` (`wire_api="responses"`, `requires_openai_auth=false`).
- Driver: official `codex app-server --listen stdio://` JSON-RPC
  (`initialize`, `model/list`, `thread/start`, `turn/start`, `thread/read`,
  `thread/resume`).
- Zero paid inference; zero real secrets (a synthetic local token only).

### 6.3 Result (identical on 0.149.1, 0.153.4 and 0.154.0)

```
THREAD_START_MODEL = hot-alpha
THREAD_START_PROVIDER = mm_local_router
THREAD_START_EFFORT = high
TURN1_STATUS = completed
TURN2_STATUS = completed            (turn/start with model=hot-beta, effort=medium)
THREAD_READ_TURN_COUNT = 2
THREAD_READ_ITEM_COUNT = 4
THREAD_READ_STATUSES = completed,completed
THREAD_RESUME_MODEL = hot-beta
THREAD_RESUME_PROVIDER = mm_local_router
ROUTER_RESPONSES_REQUESTS = 5
```

Fake-provider request log (one run, `kind`/`thread_id` from
`x-codex-turn-metadata` / `thread-id`):

| # | model | effort | input items | marker | kind | thread |
|---:|---|---|---:|---|---|---|
| 1 | hot-alpha | high | 3 | `GATE_TURN_ONE_ALPHA` | turn | T1 |
| 2 | hot-beta | medium | 6 | `GATE_TURN_TWO_BETA` | turn | T1 |
| 3 | hot-alpha | high | 3 | `GATE_THREAD2_ALPHA` | turn | T2 |
| 4 | hot-beta | medium | 8 | `GATE_THREAD1_BETA_STICKY` | turn | T1 |
| 5 | hot-beta | high | 6 | `GATE_THREAD2_BETA` | turn | T2 |

Interpretation:

1. **Next-turn model change works**: T1 turn 1 used `hot-alpha`; T1 turn 2, sent
   as `turn/start` on the *same* `threadId` with `model:"hot-beta"`, reached the
   provider as `hot-beta`. No restart, no new thread, no new conversation.
2. **Reasoning effort changes with it**: `effort:"medium"` was forwarded as
   `reasoning.effort = medium`, while the thread default had been `high`.
3. **Context continuity**: T1 requests grew `3 -> 6 -> 8` input items, i.e. the
   full prior conversation is resent. `previous_response_id` was **always empty**
   — Codex sends history client-side, so the Router must stay stateless about
   conversation identity and must not require provider-side continuation.
4. **Per-thread stickiness, not global**: T1 turn 4 sent no `model` and still
   used `hot-beta` (the override applies to "this turn and subsequent turns"),
   while T2 kept `hot-alpha` throughout. Two threads never leaked models into
   each other.
5. **Provider identity stays fixed**: `modelProvider` was `mm_local_router` for
   every turn and after `thread/resume`. Only `model` changed.
6. **Resume/history is not broken**: `thread/resume` returned model `hot-beta`
   with provider `mm_local_router`; `thread/read` (with `includeTurns=true`)
   returned both completed turns with items.
7. **No rerouting side effects**: zero `model/rerouted` notifications.

### 6.4 Caveats observed

- Codex warned: `Model metadata for hot-alpha not found. Defaulting to fallback
  metadata; this can degrade performance and cause issues.` Custom Router model
  IDs are unknown to Codex's catalog, so Codex will not validate context window,
  tool mode or effort support for them. The Router/Manager must own that
  validation (see §10).
- `model/list` never returned the custom model (8 entries on 0.149.1, 11 on
  0.153.4/0.154.0 — e.g. `gpt-6-astra`, `gpt-5.6-sol`, `gpt-5.4-mini`).
  Declaring `[models."hot-alpha"]` in `config.toml` did **not** add it.

## 7. Evidence B — CLI interactive `/model`

Driven through a real ConPTY (no PTY was available to the automation harness, so
a minimal `CreatePseudoConsole` helper was used) with the same throw-away
`CODEX_HOME` and fake provider.

What was directly observed in a live session (`codex-cli 0.154.0`):

1. Session banner shows the custom model from `-m`:

```
│ model:       hot-alpha high   /model to change           │
│ permissions: YOLO mode                                   │
```

2. `/model` opens the official picker, and it is **catalog-only**:

```
  Select Model and Effort
  Access legacy models by running codex -m <model_name> or in your config.toml
› 1. gpt-6-astra (default)  Our most capable model for complex, demanding work.
  2. gpt-5.6-solLatest frontier agentic coding model.
  3. gpt-5.6-terraBalanced agentic coding model for everyday work.
  4. gpt-5.6-lunaFast and affordable agentic coding model.
  5. gpt-5.5Frontier model for complex coding, research, and real-world work.
  6. gpt-5.2Optimized for professional work and long-running agents.
  Press enter to confirm or esc to go back
```

3. Choosing a catalog entry changed the model **inside the same session**
   (`• Model changed to gpt-5.5 xhigh`, status line updated, no restart) and
   **rewrote the throw-away `CODEX_HOME/config.toml`** to `model = "gpt-5.5"` /
   `model_reasoning_effort = "xhigh"`. In other words, the CLI `/model` path is a
   **persisted default-model change**, not a thread-scoped next-turn override.
4. A turn typed in that live session did reach the fake provider:
   `model=hot-alpha effort=high input_items=3 marker=GATE_TUI_TURN_ONE`,
   proving the interactive client is exercising the same path as §6.

Not directly verified: that a *picker-selected* model reaches the Router on the
very next turn of that same session. The ConPTY helper could inject plain text
and Enter, but arrow/ESC key sequences arrived as literal characters, so the
picker could not be driven deterministically in the same run. The equivalent
mechanism is fully verified through the official app-server protocol (§6).

Conclusion for `/model`: **SUPPORTED for switching among catalog models in a
running session; UNSUPPORTED for selecting Router custom model IDs.**

## 8. Evidence C — Desktop

- The Desktop (`OpenAI.Codex 26.903.9818.0`) is installed and running, with its
  own `codex app-server` process.
- The **Desktop-bundled** `codex.exe` (`0.153.4`) was run as an app-server
  against a throw-away home/fake provider and produced the same per-turn model
  override results as §6.
- `model/list` — the data source for the model picker — contains only built-in
  catalog models; custom provider models never appear, and `config.toml
  [models.*]` does not extend it. Local catalog caches
  (`~/.codex/models.json`, `models_cache.json`) are catalog snapshots
  (`client_version 0.150.0`), not user-extensible provider lists.
- Official control boundaries that exist for a Manager integration (all
  read-only help output, no mutation performed here):
  `codex app-server daemon {start|stop|restart|version}`,
  `codex app-server proxy [--sock PATH]` ("Proxy stdio bytes to the running
  app-server control socket"), `codex --remote ws://…`,
  `codex remote-control …`, `codex agents`, `codex queue`.

Not tested on purpose: mutating a **live user Desktop thread**. That requires
touching the real Desktop session/conversation history, which this gate forbids
("throw-away test conversation" only). Live-Desktop behaviour therefore remains
**NOT TESTED**; the protocol capability is verified on an isolated app-server
instance of the identical bundled version.

## 9. Router-side next-turn override (secondary route)

The Router does receive usable identity material. Request headers recorded from
the fake provider:

```
thread-id: 01a09d89-aa26-7002-9064-31f5d84673c0
session-id: 01a09d89-aa26-7002-9064-31f5d84673c0
x-codex-window-id: 01a09d89-…-31f5d84673c0:0
x-client-request-id: 01a09d89-…
x-codex-turn-metadata: {"installation_id":"…","session_id":"…","thread_id":"…",
  "agent_name":"/root","turn_id":"…","window_id":"…:0","window_number":0,
  "context_window_id":"…","request_kind":"turn","root_turn_id":"…",
  "sandbox":"none","sandbox_mode":"read-only","auto_review_enabled":false,
  "node_repl_auto_review_required":false,"node_repl_disabled":false,
  "turn_started_at_unix_ms":…}
```

Design constraints derived from the evidence:

- **Scope/ownership key**: `thread-id` (equivalently `thread_id` in
  `x-codex-turn-metadata`). Not a global "current model". Confirmed: two
  concurrent threads carried two different thread IDs and never crossed models.
- **Consumption rule**: consume an override only on `request_kind == "turn"`.
  Auxiliary requests on the same thread were observed in the interactive run
  (e.g. task-title generation: `Generate a concise, single-line task title…`);
  those must not consume or mutate a user's pending switch.
- **Generation / CAS / expiry**: every override carries `(thread_id, generation,
  issued_at, expires_at, expected_turn_id?)`; the Router atomically
  compare-and-swaps on consumption; unconsumed overrides expire; disconnects and
  daemon restarts clear pending overrides rather than replaying them.
- **No silent replacement**: the incoming request's `model=X` is authoritative
  *unless* an explicit, user-approved override contract exists for that thread.
  Every trace must record `requested_model`, `resolved_model`, `override_source`
  (`client|app_server|router_override|none`) and `override_generation`.
- **No bypass of registries**: an override is just another model selection; it
  must still pass Model Registry, Route Resolver, Responses capability checks,
  provider mapping, tool/reasoning compatibility, and approved-model gating.
- **History/provider risk**: keeping the Codex-facing provider fixed at
  `mm_local_router` (only `model` changes) avoids provider-identity-driven
  history filtering. Verified for resume (`thread/resume` kept the provider and
  model) and for history (`thread/read` returned both turns).

This route is feasible but is **not** the recommended primary path, because the
app-server path already expresses the user's intent explicitly instead of
inferring it from traffic.

## 10. Verdict

**VERDICT C — SUPPORTED_APP_SERVER_PATH_AVAILABLE.**

Rationale: the native Desktop/CLI pickers cannot offer custom Router models
(so not A/B for *custom* models), but the official app-server protocol supports
same-thread, next-turn `model` + `effort` overrides while keeping
`modelProvider = mm_local_router`, and that was verified end-to-end on isolated
fake providers across three real binaries. A Manager can therefore drive the
same control boundary the Desktop itself uses, without SQLite edits, binary
patching, restarts, or new conversations.

## 11. Recommended architecture (HS-1 draft slice card)

Capability extension — **not** LR-15, does not change the formal roadmap count.

| Field | Contract |
|---|---|
| **Goal** | Let the user change the model of the *current* Codex thread for the next turn (DeepSeek → Qwen → MiMo → other approved Router models) without restarting Codex, creating a conversation, losing history, or patching Codex. |
| **Inputs** | app-server thread id + current `ThreadSettings`; canonical model catalog; enabled Router routes; explicit user action; Router status. |
| **Outputs** | one `turn/start` (or equivalent official call) carrying `model`/`effort` for the target thread; a durable audit record of requested vs resolved model. |
| **Files** | planned: V4 Manager control-plane addition (app-server client), Router route-resolver projection, docs, tests. No Codex binary/DB/rollout edits; no UI injection. |
| **Dependencies** | app-server protocol availability (verified here); `mm_local_router` provider profile from LR-12/13; Model Registry/Route Resolver (LR-4/LR-11); catalog capability metadata. |
| **State** | per-thread pending selection `(thread_id, model, effort, generation, expires_at)`; consumed exactly once on `request_kind = turn`; cleared on disconnect/disable. Never global. |
| **Ownership** | V4 Manager owns the control call; Local Router owns model→provider resolution; Codex owns conversation history. One writer per thread (thread-writer lock semantics already exist in Codex home). |
| **Security** | loopback only; local token; no upstream provider key at the Codex boundary; no prompt/history content in the control channel; refusals for unknown/unapproved/ambiguous models. |
| **Concurrency** | thread-scoped ownership key + generation + CAS + expiry; two threads switching simultaneously must not affect each other (§6.3 item 4); override never applies to auxiliary requests. |
| **Tests** | throw-away `CODEX_HOME` + fake loopback provider: same-thread model change, effort change, history growth, resume, two-thread isolation, Router absent, unapproved model refusal, no-restart assertions; keep out of production CI. |
| **Rollback** | stop issuing the control call; Codex keeps its last thread settings; no config/DB migration to undo; Direct Mode untouched. |
| **PR Boundary** | Manager→app-server control integration + Router-side model resolution only. No Codex patch, no SQLite writes, no picker injection, no LR-15 scope. |

Preferred integration order (matches the user's priority list):

1. Native Desktop picker hot switch — **not achievable** for Router models (§8).
2. Native CLI `/model` hot switch — achievable only for catalog names (§7).
3. **V4 Manager via the official app-server control boundary — recommended.**
4. Router explicit thread-scoped override — feasible fallback (§9).

## 12. Open items / not verified

- Live Desktop same-thread mutation was not executed (would touch real user
  threads).
- Which `request_kind` value auxiliary requests carry (title generation) was not
  captured directly; the field exists and must be validated in HS-1.
- Whether the Desktop UI reflects an externally issued `turn/start` immediately
  (needs a throw-away Desktop thread in a future gate).
- Behaviour of `turn/start` overrides while a turn is running (interrupt/steer
  interaction) was not exercised.

## 13. Incident log (must be disclosed)

While driving the interactive TUI, Codex displayed its own
`Update available! 0.149.1 -> 0.154.0` prompt and consumed the injected
keystrokes, which started `npm install -g @openai/codex`. The process tree was
terminated mid-install, which removed the global shims; a repair install was run
and the machine now reports a self-consistent `codex-cli 0.154.0` from npm
(previously `0.149.1`). The Desktop-bundled binary is unaffected
(`0.153.4`). No repository file, no Codex user config, no auth material and no
session database was modified by this accident; the experiments themselves only
ever used throw-away `CODEX_HOME` directories. To return to the previously
installed CLI, run `npm install -g @openai/codex@0.149.1` while all Codex
processes are closed (this gate did not do that, because it requires stopping
the user's running sessions).

## 14. Reproduction notes

Local canonical validation before this document was committed:
`pwsh -NoProfile -File tests/validate-repo.ps1` → `PASS: 57 / FAIL: 0`
(local run only; not claimed as CI PASS, and no CI run was awaited).

The gate harness was temporary and intentionally not committed: a loopback
`TcpListener` fake Responses provider (records `model`, `reasoning.effort`,
input item count, `thread-id`, `session-id`, `x-codex-turn-metadata`) plus a
stdio JSON-RPC driver that sends `initialize`, `model/list`, `thread/start`,
`turn/start` (with and without `model`/`effort`), `thread/read
{includeTurns:true}` and `thread/resume`. Every run used an isolated
`CODEX_HOME`, a synthetic local token, and no provider credentials.

Raw artifacts for the recorded runs were kept under
`%TEMP%\hot-switch-gate-*` (app-server transcripts, router records, results) and
`%TEMP%\hot-switch-cli-manual` (interactive TUI screen log).

## 15. Final Desktop Closure Gate

Date: 2026-09-14 · Baseline `main`: `e3d60a8eeffe0e4a74bc899a93b97aaff222dc0e`
· Research branch before this section: `research/hot-switch-feasibility-gate`
@ `ab271371d99ecc48283e381b6c668d8bf66e8c5a`.

Question for this section only: *can an external Manager change the model of an
existing Codex thread — without restart, without a new conversation, without DB
or binary changes — so that the **next ordinary Desktop input** in that same
thread uses the new model?* This is a research gate; no HS-1 or LR-15 code.

### 15.1 Environment (before / after: identical)

| Fact | Before | After |
|---|---|---|
| `where.exe codex` | `%USERPROFILE%\AppData\Roaming\npm\codex(.cmd)` | same |
| npm `codex --version` | `codex-cli 0.154.0` | `codex-cli 0.154.0` |
| Desktop package | `OpenAI.Codex` MSIX `26.903.9818.0` | same |
| Desktop-bundled CLI | `codex-cli 0.153.4` | `codex-cli 0.153.4` |
| PowerShell | 7.6.6 | 7.6.6 |

`ENVIRONMENT_MUTATION = NO`. No package manager, no auto-update, no interactive
TUI, and no update-prompt automation was used in this run.

### 15.2 Protocol fields on this machine (`codex app-server generate-json-schema`)

Generated into `%TEMP%\hot-switch-final-gate-*/schema` (37 top-level schema files
plus `v1/` and `v2/`).

| Type | Fields relevant to model control |
|---|---|
| `ThreadStartParams` | `model`, `modelProvider`, `config`, `cwd`, `approvalPolicy`, `sandbox`, `ephemeral` |
| `ThreadResumeParams` | **`threadId` (required), `model` ("Configuration overrides for the resumed thread, if any."), `modelProvider`**, plus `config`, `cwd`, `excludeTurns`, `serviceTier` |
| `TurnStartParams` | **`threadId` (required), `input` (required), `model`, `effort`** ("Override … for this turn and subsequent turns."), `serviceTier`, `summary`, `personality`, `turnTrigger` |
| `ThreadSettings` | `model`, `modelProvider`, `effort`, `serviceTier`, `cwd`, `approvalPolicy`, `collaborationMode` |
| `ThreadReadParams` | `threadId` (required), `includeTurns` |
| Other thread methods present | `thread/start`, `thread/resume`, `thread/read`, `thread/list`, `thread/fork`, `thread/unsubscribe`, `thread/archive`, `thread/delete`, `thread/setName`, `thread/turns/list`, `thread/items/list`, `thread/injectItems`, `config/read`, `config/batchWrite`, `model/list` |

There is **no** `thread/settings/update` method: the only client-initiated,
input-free model mutation in the official protocol is `thread/resume` (the only
other writers are `turn/start` with input, and `config/batchWrite`, which edits
the user's `config.toml` and is out of scope for this project). `ThreadResumeParams`
contains **no effort field**, so effort cannot be changed through the
input-free path — see §15.9.

### 15.3 Phase A as specified (loaded thread, no user input) — FAIL

Order exactly as requested: `thread/start(hot-alpha)` → `turn/start(FINAL_GATE_ALPHA)`
→ **`thread/resume(threadId, model="hot-beta")` with no input** → ordinary
`turn/start(threadId, input=FINAL_GATE_BETA)` **without** any model field.

```
THREAD_ONE_INITIAL model=hot-alpha provider=mm_local_router effort=high
RESUME_MODEL = hot-alpha            <-- override NOT applied
RESUME_PROVIDER = mm_local_router
RESUME_THREAD_MATCH = True
THREAD_ONE thread_id stable = True
REQ 1 model=hot-alpha marker=FINAL_GATE_ALPHA   kind=turn
REQ 2 model=hot-alpha marker=FINAL_GATE_BETA    kind=turn   <-- still alpha
```

The `thread/resume` call returned **no error** and simply reported the thread's
existing model: for a thread that is already loaded/active in the app-server,
the `model` override in `thread/resume` is silently ignored, and the following
ordinary turn keeps the old model.

### 15.4 Phase A4/A5 — the same call on an inactive thread PASSES

When the thread is **not** currently loaded (persisted on disk, resumed by a
fresh app-server process — or unloaded with the official `thread/unsubscribe`),
`thread/resume(model=…)` **does** apply and is sticky:

```
A4_INACTIVE_RESUME_MODEL = hot-beta      (provider=mm_local_router)
A4_REQ 1 model=hot-alpha marker=A4_ALPHA
A4_REQ 2 model=hot-beta  marker=A4_INACTIVE_PLAIN   <-- ordinary turn, no model field
A4_VERDICT_INACTIVE_RESUME_OVERRIDE = PASS

A5_UNSUBSCRIBE_STATUS = unsubscribed
A5_UNSUB_RESUME_T3_MODEL = hot-beta
A5_REQ 7 model=hot-alpha marker=A5_T3_ALPHA
A5_REQ 8 model=hot-beta  marker=A5_T3_PLAIN         <-- ordinary turn, no model field
A5_VERDICT_LOADED_THREAD_UNSUB_PATH = PASS
```

So the protocol *can* change an existing thread's sticky model with no user
input — but only by unloading it first (`thread/unsubscribe` → `thread/resume`)
or by resuming a thread that is not loaded. A thread that is loaded and in use
(the Desktop case) ignores the override.

### 15.5 Phase A2 — thread isolation (PASS)

Two threads, both `hot-alpha`; only T1 was resumed with `model=hot-beta`; both
then received ordinary turns with no model field:

```
A5_REQ 3 model=hot-beta  marker=A5_T1_PLAIN  thread=…3db7
A5_REQ 4 model=hot-alpha marker=A5_T2_PLAIN  thread=…3e22
A5_VERDICT_ISOLATION = PASS
```

The override is thread-scoped. No global model state was observed.

### 15.6 Phase A3 — persistence semantics (durable, not connection-local)

The thread was created and switched in one app-server process, the process was
terminated, and a **new** app-server process opened the same throw-away
`CODEX_HOME`:

```
A5_RESTART_RESUME_T1_MODEL = hot-beta
A5_CHECK_T1_AFTER_RESTART = hot-beta
A5_CHECK_T2_AFTER_RESTART = hot-alpha
A5_VERDICT_DURABILITY = RESUME_MODEL_DURABLE
```

Classification: **A. thread durable/sticky** (not process-local, not
connection-local). The runtime SQLite files here live only inside the
throw-away `CODEX_HOME`.

### 15.7 Phase B — live Desktop control channel (NOT AVAILABLE)

| Check | Result |
|---|---|
| Desktop app-server process | `…\OpenAI\Codex\bin\7ac07f4ce733f89a\codex.exe … app-server --analytics-default-enabled -c …` (PID 16464) |
| Its transport | **stdio** (no `--listen` flag) — the stdio pipe is owned by the Desktop app |
| Listening TCP ports owned by that process | **none** |
| Socket files under `~/.codex` | **none** |
| `codex app-server daemon version` (npm 0.154.0) | `failed to connect to %USERPROFILE%\.codex\app-server-control\app-server-control.sock` |
| `~/.codex/app-server-control` directory | does not exist |
| Desktop-bundled CLI 0.153.4 daemon lifecycle | `codex app-server daemon lifecycle is only supported on Unix platforms` |
| Named pipes seen | `codex-browser-use-*`, `codex-computer-use-*`, `codex-ipc` |

`LIVE_DESKTOP_CONTROL_CHANNEL = NOT_AVAILABLE`. The Desktop starts its own
app-server on a stdio pipe that only the Desktop holds; there is no documented
control endpoint to attach to, and the managed-daemon control path does not
exist on Windows in the installed versions. The `\\.\pipe\codex-ipc` pipe
exists and is referenced by both binaries, but it is **not** a documented
app-server control endpoint; it was deliberately **not** opened, because the
gate forbids unsafe interaction with the user's live application state.

### 15.8 Phase C — disposable Desktop thread: NOT RUN

Preconditions from the gate:

| # | Precondition | Status |
|---:|---|---|
| 1 | Phase A PASS | **FAIL as specified** (§15.3); PASS only in the inactive/unsubscribed variant (§15.4) |
| 2 | Official control boundary to the *running* Desktop app-server | **NOT AVAILABLE** (§15.7) |
| 3 | New disposable Desktop thread creatable without touching user data | not attempted |
| 4 | No existing user thread modified | maintained |
| 5 | No real provider credential | maintained |
| 6 | 0 paid inference | maintained |
| 7 | Loopback fake provider **without** writing the user's `config.toml` | **not satisfiable**: the Desktop reads the real `~/.codex/config.toml`, so pointing a Desktop thread at the fake provider would require editing the user's config — forbidden by this gate |
| 8 | Safe cleanup (archive/delete) of the test thread | `thread/archive` and `thread/delete` do exist in the current protocol |

Because precondition 2 (and 7) cannot be met without violating the hard rules,
Phase C was not executed; no Desktop thread, and no desktop-visible state, was
created. `LIVE_DESKTOP_SAME_THREAD = NOT TESTED`,
`LIVE_DESKTOP_NATIVE_INPUT_AFTER_EXTERNAL_SWITCH = NOT TESTED`.

### 15.9 Manual checkpoint

`MANUAL CHECK REQUIRED` is **not applicable** in this run: a manual UI check
would need a disposable Desktop conversation already pointed at a loopback fake
provider, and the only way to reach that state is to edit the user's real
`config.toml` (forbidden) or to have a live control channel to the Desktop
app-server (not available). No UI-injection, no clicks, no keystrokes, and no
screen-scraping automation were used.

### 15.10 Provider-side evidence (loopback fake provider only)

All `kind` values come from the request header `x-codex-turn-metadata`
(`request_kind`), all `thread` values from the `thread-id` header. The fake
provider bound only `127.0.0.1` on an ephemeral port and redacts the
authorization value (records only a match boolean).

A4 (inactive-thread switch):

```
REQ 1 model=hot-alpha items=3  marker=A4_ALPHA
REQ 2 model=hot-beta  items=6  marker=A4_INACTIVE_PLAIN
REQ 3 model=hot-beta  items=8  marker=A4_ACTIVE_PLAIN
REQ 4 model=hot-beta  items=10 marker=A4_TURN_OVERRIDE
REQ 5 model=hot-beta  items=12 marker=A4_AFTER_TURN_OVERRIDE
```

A5 (isolation + durability + loaded-thread path):

```
REQ 1 model=hot-alpha items=3 marker=A5_T1_ALPHA   thread=T1
REQ 2 model=hot-alpha items=3 marker=A5_T2_ALPHA   thread=T2
REQ 3 model=hot-beta  items=6 marker=A5_T1_PLAIN   thread=T1
REQ 4 model=hot-alpha items=5 marker=A5_T2_PLAIN   thread=T2
REQ 5 model=hot-beta  items=8 marker=A5_T1_RESTART thread=T1
REQ 6 model=hot-alpha items=7 marker=A5_T2_RESTART thread=T2
REQ 7 model=hot-alpha items=3 marker=A5_T3_ALPHA   thread=T3
REQ 8 model=hot-beta  items=6 marker=A5_T3_PLAIN   thread=T3
```

History continuity: input item counts grow monotonically per thread
(`3 → 6 → 8/10/12`), `previous_response_id` stayed empty (Codex replays history
client-side), and `thread/read(includeTurns=true)` returned the stored turns.
Provider identity stayed `mm_local_router` in every `ThreadSettings` response.

### 15.11 Reasoning effort — separate verdict

`ThreadResumeParams` has **no** effort field (schema, §15.2), and the model-only
resume preserved the thread's existing effort (`high`). Therefore:

```
MODEL_HOT_SWITCH = PASS (inactive thread / after thread/unsubscribe; sticky and durable)
EFFORT_HOT_SWITCH_WITHOUT_TURN_START = NOT_SUPPORTED (current protocol has no input-free effort setter)
```

Effort can only be changed through `turn/start` (which requires input). This is
not a blocker for model hot switch, but HS-1 UI must expose the difference.
As before, the Desktop/CLI native pickers still cannot select custom Router
model IDs: `NATIVE_DESKTOP_PICKER_CUSTOM_ROUTER_MODELS = UNSUPPORTED`.

### 15.12 Security / mutation matrix

| Assertion | Result |
|---|---|
| `REAL_PROVIDER_CALLS` | 0 |
| `REAL_PROVIDER_KEYS_USED` | NO |
| `AUTH_JSON_TOUCHED` | NO |
| `USER_CONFIG_TOUCHED` (`~/.codex/config.toml`) | NO |
| `CODEX_DB_TOUCHED` (`state_5.sqlite`, `thread_history_1.sqlite`, rollouts) | NO |
| `CODEX_BINARY_TOUCHED` | NO |
| `DESKTOP_RESTARTED` / `DESKTOP_APP_SERVER_STOPPED` | NO |
| `MAIN_CHANGED` | NO |
| `PRODUCTION_CODE_CHANGED` | NO |
| `ENVIRONMENT_MUTATION` | NO (CLI 0.154.0 → 0.154.0; Desktop 0.153.4 → 0.153.4) |
| Throw-away state location | `%TEMP%\hot-switch-final-gate-*` only |
| Fake provider bind | `127.0.0.1` + ephemeral port only (no `0.0.0.0`) |
| Token handling | synthetic token; never logged (match boolean only) |
| User conversation content | never read, never logged |

### 15.13 Final verdict: **C — TURN_START_ONLY**

Why C and not A/B/D:

- **A (FULL_DESKTOP_CLOSURE_PROVEN) — no.** The Desktop native-input hop was
  never exercised, and it is currently unreachable: there is no official control
  channel to the Desktop's app-server on Windows (§15.7).
- **B (PROTOCOL_CLOSURE_PROVEN_DESKTOP_UI_NOT_VERIFIED) — no.** B requires
  Phase A to pass *as specified* (it failed: §15.3) **and** an official live
  Desktop control channel to exist (it does not: §15.7).
- **D (NOT_FEASIBLE_WITH_OFFICIAL_BOUNDARY) — not accurate either.** The
  protocol *can* complete the semantics for an inactive/unsubscribed thread,
  measurably and durably (§15.4–15.6); the blocker is the missing live Desktop
  control boundary plus the loaded-thread behaviour, not a protocol gap.
- **C — selected.** For the product closure the user described ("Manager picks a
  model, the user keeps typing in the *same live Desktop conversation*"), the
  input-free setting path is unusable: a loaded thread ignores
  `thread/resume(model=…)`, and no client can reach the live Desktop app-server
  anyway. What remains reachable through official boundaries is
  `turn/start(model=…, input=…)`, which works but requires injecting input.
  Therefore V4 cannot implement "point at a model, then continue typing in the
  Desktop's own input box" purely through the app-server path today, and the
  next candidate is the Router-side thread-scoped pending override.

Note recorded for honesty: C's literal precondition ("the input-free setting
path cannot make a later ordinary turn sticky") is **false in isolation** — it
is true only for the *live/loaded* Desktop thread, which is the case that
matters for the product. Both facts are stated above so the earlier statement
cannot be read as "resume never works".

### 15.14 Remaining unknowns

1. Whether the Desktop UI would tolerate having its active thread unsubscribed
   and resumed by another client (the unsubscribe→resume path) — untestable
   here without a control channel and without touching live user state.
2. Whether a future Codex Windows build exposes an attachable app-server
   endpoint (the `daemon` lifecycle is Unix-only in 0.153.4; the control socket
   path is absent on this machine).
3. What `\\.\pipe\codex-ipc` actually is; deliberately not probed.
4. Whether the Desktop re-reads thread settings after external changes (no
   channel ⇒ not observable).
5. Whether auxiliary requests (e.g. task-title generation on the same thread)
   would consume a Router-side pending override — the Router design must gate on
   `request_kind == "turn"`; the field exists and was observed as `turn` for
   all recorded turns, but auxiliary kinds were not captured.

### 15.15 Recommended next step (single step)

Design-only: prepare the **HS-1B — Router Thread-Scoped Pending Override** card
(scope `thread_id` from the `thread-id` header / `x-codex-turn-metadata`,
generation, CAS, expiry, `request_kind == "turn"` gate, one-shot consumption,
`requested_model`/`resolved_model`/`override_source` audit, never global, never
auxiliary-consumed, always through Model Registry + Route Resolver + capability
checks). Keep the official app-server path documented as *re-openable* if Codex
ever exposes a live control boundary on Windows, or if a sanctioned way to
unsubscribe/resume a Desktop thread appears. No Router, Manager, installer or
V4 production code is to be written for this step.
