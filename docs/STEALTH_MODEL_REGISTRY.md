# Stealth Model Registry

Version introduced: **3.3.0**

The Stealth Model Registry tracks anonymous/stealth model aliases across their lifecycle without silently changing the user's default Codex model.

## Why it exists

An anonymous model can start with a temporary ID such as:

```text
stealth/ox-alpha
```

Later, the model may be:

- officially revealed under a vendor/model ID;
- kept alive under the old stealth ID for a transition period;
- removed while a replacement ID appears;
- removed without a confirmed replacement.

A hard-coded launcher cannot safely handle all of these states. The registry preserves the alias and history, then resolves the alias to the currently confirmed model ID.

## Runtime storage

The registry is user-level and is never stored inside project repositories:

```text
~/.codex/multimodel-manager/stealth-models.json
~/.codex/multimodel-manager/stealth-model-history.jsonl
```

The initial seed currently tracks:

```text
Alias: Ox Alpha
Original/current ID: stealth/ox-alpha
Provider: mm_openrouter
```

## Status model

- `TRACKING`: registry entry exists but has not yet been synced.
- `ACTIVE_STEALTH`: current anonymous ID is still present.
- `MISSING_NEEDS_REVIEW`: current anonymous ID disappeared and no confirmed replacement is recorded.
- `REVEAL_RECORDED`: the user explicitly recorded a replacement; a follow-up sync will verify availability.
- `REVEALED_ACTIVE`: confirmed replacement ID is present and becomes the alias's resolved ID.
- `REVEAL_RECORDED_OLD_ID_ACTIVE`: replacement is temporarily unavailable but the old anonymous ID is still live; launcher falls back to the old ID.
- `REPLACEMENT_MISSING`: neither the recorded replacement nor the old current ID is available.

## Automatic behavior

`CHECK_NEW_MODELS.cmd` and scheduled discovery also run a stealth registry sync.

Automatic sync may:

- read OpenRouter `/api/v1/models`;
- initialize the local registry;
- update status/last-seen timestamps;
- notice when a tracked anonymous ID disappears;
- show metadata-based **suspected** replacement candidates;
- write user-level status history.

Automatic sync must **not**:

- declare a suspect to be the official replacement;
- modify Codex `config.toml`;
- launch a model;
- run paid inference;
- replace GPT-5.6 or another fallback;
- modify project files.

## Recording an official reveal

When a vendor/OpenRouter officially identifies the replacement, open:

```text
installer/STEALTH_MODEL_REGISTRY.cmd
```

Choose **Record official reveal / new model ID**.

The script:

1. verifies the new model ID is currently present in OpenRouter's catalog;
2. shows old alias/current ID and proposed new ID;
3. requires the exact confirmation `MIGRATE`;
4. preserves the original anonymous ID as history;
5. stores the replacement ID and official name;
6. does not change the default Codex model or project code.

## Alias-based launch

The generic launcher resolves the alias at launch time:

```text
Alias
  -> confirmed replacement ID, if live
  -> otherwise old current ID, if still live
  -> otherwise stop safely
```

Ox Alpha remains available through:

```text
installer/LAUNCH_OX_ALPHA_EXPERIMENTAL.cmd
```

but that entrypoint now delegates to the generic registry launcher. Therefore, if Ox Alpha is later officially revealed and the replacement is recorded, the same launcher can follow the confirmed mapping without hard-coding a new model ID.

## Safety principle

**Detection can be automatic; identity migration cannot be silent.**

A model name, description, or nearby release date can suggest a replacement, but only an explicit user-approved `MIGRATE` operation records the official mapping.
