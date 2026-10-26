# Ox Alpha experimental integration

Status: **EXPERIMENTAL / STEALTH**

Recorded on: 2026-08-22

Current tracked alias:

```text
Ox Alpha
```

Initial OpenRouter model ID:

```text
stealth/ox-alpha
```

Current OpenRouter catalog information at the time of integration indicated that Ox Alpha was a reasoning model aimed at coding, sustained agentic work, and production workloads, with a large context window, tool calling, and reasoning controls.

Because the model is anonymous/stealth, its underlying identity, routing, availability, pricing, and behavior can change. This repository therefore does **not** make Ox Alpha a default fallback and does **not** automatically replace GPT-5.6 with it.

## V3.3 lifecycle behavior

Ox Alpha is now managed by the generic **Stealth Model Registry** rather than being permanently hard-coded to `stealth/ox-alpha`.

Runtime state is stored under:

```text
~/.codex/multimodel-manager/stealth-models.json
```

The registry preserves:

- alias: `Ox Alpha`;
- original/current anonymous ID: `stealth/ox-alpha`;
- current lifecycle status;
- confirmed replacement ID, if one is later recorded;
- official revealed name, if known;
- timestamps and status history.

When `stealth/ox-alpha` disappears, the registry marks it `MISSING_NEEDS_REVIEW` and may display metadata-based suspected replacements. It will **not** automatically declare a replacement.

When the model is officially revealed, use:

```text
installer/STEALTH_MODEL_REGISTRY.cmd
```

and record the new OpenRouter model ID. The migration requires the exact confirmation `MIGRATE` and validates that the new ID is live before saving it.

After a confirmed migration, the Ox Alpha launcher resolves the alias to the replacement ID automatically while retaining the old anonymous ID as historical information.

## Requirements

1. Configure OpenRouter using `installer/ONE_CLICK_SETUP.cmd`.
2. `OPENROUTER_API_KEY` must exist as a Windows user/process environment variable for actual model launch.
3. The generated Codex config must contain the `mm_openrouter` Responses provider.
4. The launcher verifies the resolved alias target is still present in OpenRouter's current `/api/v1/models` catalog.
5. The user must explicitly type `OX` before the Ox Alpha alias is launched.

## Launch

From `installer/`:

```text
LAUNCH_OX_ALPHA_EXPERIMENTAL.cmd
```

Or choose Ox Alpha from the normal model switcher.

The dedicated Ox Alpha launcher now delegates to:

```text
launch-stealth-model.ps1 -Alias "Ox Alpha" -ConfirmationCode "OX"
```

The generic launcher resolves the currently confirmed model ID, then starts Codex with the existing OpenRouter Responses provider.

No real API key value is written to this repository or to the generated TOML.

## Project safety

Before launching from inside a Git repository, the launcher calls the existing Git handoff snapshot logic when available. It never runs `git reset`, `git clean`, or `git stash`.

For private core code, business secrets, credentials, or other sensitive content, review the current OpenRouter and routed-provider data policies before using an anonymous model.

See `docs/STEALTH_MODEL_REGISTRY.md` for the full reveal/migration lifecycle.

## Sources

- OpenRouter model catalog: https://openrouter.ai/api/v1/models
- OpenRouter base API: https://openrouter.ai/api/v1
