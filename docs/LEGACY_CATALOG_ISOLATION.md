# Legacy Custom Model Catalog Isolation

Codex supports `model_catalog_json` as a profile-scoped setting. A legacy configuration that places a provider-specific catalog at the root of `~/.codex/config.toml` applies that catalog globally, including to ChatGPT/OpenAI sessions.

That can make `/model` show only the old custom catalog and can cause a Manager profile to select a model name that the signed-in ChatGPT account does not actually support.

## 3.3.7 behavior

When the migration helper finds both of these root settings:

- `model_provider = "<non-openai provider>"`
- `model_catalog_json = "..."`

it moves the root model-specific settings into:

`~/.codex/legacy-codex-catalog.config.toml`

The preserved profile can still be launched from Model Switcher option 8. The shared provider definition remains in the base config.

The ChatGPT Manager profile keeps `model_provider = "openai"` and the reasoning preference, but does not hard-code `model = "gpt-5.6"`. Codex therefore selects the official model currently supported by the signed-in ChatGPT account.

## Safety boundaries

- The old custom catalog file itself is not deleted or rewritten.
- The preserved legacy profile is not recorded as a Manager-owned disposable profile.
- Unrelated user profile tables and provider definitions are preserved.
- No API keys are written to profile files.
- Git repositories and project files are not modified by this migration.
