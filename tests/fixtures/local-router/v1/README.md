# Local Router v1 test fixtures

Fixture root defined by `docs/LOCAL_ROUTER_RUNTIME_CONTRACTS.md`
(`tests/fixtures/local-router/v1/`). All fixtures are static, secret-free, and
used only by local-router unit tests.

## config/

- `default-disabled.json` — golden copy of the checked-in v1 defaults
  (`local-router/config/router.defaults.json`). Must stay byte-identical to the
  production defaults file; the loader test asserts equality.
- `merge-user-override.json` — a partial user config exercising field-level
  merge (port, limit, version).
- `invalid/` — user/defaults shapes that MUST fail closed with a specific
  `RouterError` code. Never weaken assertions; they are negative fixtures.

## migration/

- `legacy-predecessor.json` — **test/legacy fixture only**. The contract defines
  no public v0 schema; this shape exists solely to exercise the versioned
  migration machinery (`MigrationPlanner`/`MigrationRunner`) with a synthetic
  N-1 predecessor. It is never registered as a production schema and must not be
  treated as an official v0.

## state/ and ownership/

- Corrupt / invalid-shape fixtures proving quarantine and fail-closed behavior.

## responses/ (LR-3)

All `responses/` fixtures are **synthetic and scrubbed**: they contain no real
user prompt, no provider secret, no paid response dump, and no project path.
Provenance is the LR-3 canonical contract (OpenAI Responses V1 subset) with
placeholder models (`synthetic-model-v1`) and placeholder IDs.

- `request.*.json` — supported canonical request shapes (text, instructions,
  reasoning, function tool definition, function tool result, stream) plus
  negative fixtures (`background-rejected`, `multimodal-rejected`) that MUST
  fail closed with `unsupported_capability`.
- `response.*.json` — synthetic canonical non-stream responses (text,
  reasoning, tool call, usage).
- `stream.*.sse` — canonical SSE framing sequences (basic, reasoning,
  tool-call, error).
- `error.*.json` — canonical normalized error envelopes.

No fixture contains a real or fake secret value, `auth.json`, `.env` content, or
request content.
