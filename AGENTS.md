# Development Gate — Codex Multi-Model Manager

This repository is a standalone Codex utility. It must remain isolated from all other, unrelated product repositories.

## Scope

- Only edit files in this repository.
- Never read or copy secrets, API keys, `auth.json`, project `.env` files, or unrelated repositories into this project.
- Provider configuration examples must reference environment-variable names only, never secret values.

## Development gate

1. Work on one explicit task at a time.
2. Before changes, inspect `git status`, branch, recent commits, and applicable docs.
3. Do not overwrite uncommitted user work.
4. Never force-push.
5. Never commit secrets or generated runtime state.
6. Do not claim PASS for checks that were not executed.
7. Prefer additive, backward-compatible changes to managed config blocks.
8. Never make model switching run `git reset`, `git clean`, or `git stash` automatically.
9. Paid inference probes require explicit user confirmation.
10. Automatic discovery may read model-list endpoints but must not silently approve/register/activate models.
11. Stealth-model discovery may update user-level lifecycle state, but it must not silently infer identity, record a replacement, or migrate an alias. Confirmed reveal migration requires a live replacement ID plus explicit user confirmation.
12. Before changing Codex config, preserve backup/rollback behavior.
13. Finish with self-check, tests/static validation, diff review, then commit/push when requested.

## CI gate

The repository has a GitHub Actions workflow named **Development Gate**.

- Every pull request targeting `main` must run the `development-gate` job.
- Every push to `main` reruns the same validation.
- Do not merge a pull request when the `development-gate` job is failing.
- Do not describe CI as PASS until the GitHub Actions run actually completed successfully.
- Keep CI non-destructive: it may parse/inspect repository files but must not call paid model inference, mutate Codex user configuration, or modify external projects.
- The canonical CI validation script is `tests/validate-repo.ps1`; local validation should run that same script before push when practical.

The CI gate checks at minimum:

- repository, Skill, installer, and documentation structure;
- PowerShell syntax for all tracked `.ps1` files;
- Codex Skill frontmatter;
- installer-to-Skill path integrity;
- required runtime scripts in both installer and Skill payloads;
- absence of automatic `git reset`, `git clean`, `git stash`, and force-push behavior;
- absence of legacy active `wire_api = "chat"` configuration;
- common committed credential/token formats;
- absence of tracked Codex auth/runtime state;
- Windows entrypoint target integrity;
- stealth-model alias/migration safety and installer-to-Skill script parity.

## Compatibility rule

Current Codex custom providers are treated as Responses API providers. Do not reintroduce legacy `wire_api = "chat"` into active configuration logic.
