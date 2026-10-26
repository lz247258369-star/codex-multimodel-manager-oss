# Codex Profile V2 Migration

Current Codex CLI resolves `--profile <name>` from a dedicated user-level file:

`~/.codex/<name>.config.toml`

The base `~/.codex/config.toml` may continue to contain shared provider definitions under `[model_providers.*]`, but a selected profile must not also exist there as a legacy `[profiles.<name>]` table.

Codex Multi-Model Manager 3.3.6 therefore migrates Manager-owned profiles as follows:

- shared provider definitions remain in `~/.codex/config.toml`;
- each Manager profile becomes `~/.codex/<profile-id>.config.toml`;
- the old `CODEX AUTO MODELS` profile block is converted to dedicated profile files;
- a legacy root `profile = "..."` selector is removed only when it points to a Manager-owned profile;
- unrelated user configuration and unrelated legacy profiles are preserved;
- no API key is written to `config.toml` or profile files.

The Model Switcher runs this migration before launch so an existing installation is upgraded automatically. Setup also runs it immediately after refreshing Manager configuration.

Manager-owned profile files are tracked in:

`~/.codex/multimodel-manager/profile-v2-files.json`

That ownership list is used when the user explicitly removes the Manager configuration, so unrelated profile files are not deleted.
