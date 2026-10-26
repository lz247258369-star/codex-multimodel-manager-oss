# Local Router Protocol Capability Matrix

Status: **normative LR-8 capability matrix; no conversion implementation**

Matrix version: `local-router-protocol-capability-matrix/v1`

## Scope

This matrix describes protocol-layer capabilities only. Provider, model, and
route capability declarations still intersect with this matrix before a
request is served. Any capability not listed as SUPPORTED is UNSUPPORTED and
fails closed; there is no best-effort or lossy mode.

## protocol.openai.responses.v1 (canonical -> upstream)

| Capability | Status | Notes |
|---|---|---|
| text | SUPPORTED | Lossless text/instructions/input items |
| streaming | SUPPORTED | Responses SSE semantics, order preserved |
| reasoning | SUPPORTED | Preserved only when canonical + upstream + provider + model + route all declare it |
| tools | SUPPORTED | Definitions, tool_choice, call IDs, arguments preserved; router never executes tools |
| tool results | SUPPORTED | function_call_output round-trip preserved verbatim |
| usage | SUPPORTED | Provider-reported counts normalized; unknown stays null |
| cancellation | SUPPORTED | First-output checkpoint inherited from LR-3/LR-5 |
| metadata | SUPPORTED | Safe metadata fields preserved without content logging |
| multimodal | UNSUPPORTED | Any image/audio/video semantic fails closed; no text placeholder |
| background | UNSUPPORTED | Background/stored Responses fail closed |
| chat completions | UNSUPPORTED | Responses-to-Chat conversion is inactive; no `wire_api = "chat"` |

## Placeholders

| Protocol | Status | Notes |
|---|---|---|
| `protocol.anthropic.messages.v1` | PLACEHOLDER | `eligible=false`, no capabilities, no implementation |

Placeholder protocols cannot resolve, route, execute, or convert. Adding a real
protocol requires a new adapter slice that reuses the LR-8 protocol conformance
suite and proves lossless semantics.
