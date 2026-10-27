# Contributing

Thank you for helping. This project changes Codex configuration and handles
Provider credentials, so every change goes through the same safety rules.

## Licence of contributions

By submitting a contribution you agree that it is licensed under the
[Apache License 2.0](LICENSE), the licence of this repository (section 5 of the
licence).

## Ground rules

- Read [AGENTS.md](AGENTS.md); its Development Gate rules apply to every change.
- One focused change per pull request, targeting `main`.
- Never commit secrets, API key values, Codex `auth.json`, `config.toml`,
  `router.config.json`, runtime state, logs or personal data. Provider examples
  reference **environment-variable names only**.
- Never add automatic `git reset`, `git clean`, `git stash` or force-push
  behaviour, and never reintroduce legacy `wire_api = "chat"` configuration.
- Paid model inference must never run in tests or CI.
- Do not weaken a security check to make a test pass.

## Development Gate

Pull requests must pass the **Development Gate** workflow (`development-gate`).
Run the canonical validation locally before opening a pull request:

```powershell
pwsh -NoProfile -File tests/validate-repo.ps1 -RepositoryRoot $PWD
```

Requirements: Windows, PowerShell 7, Git, and the .NET SDK pinned in
`local-router/global.json`. A check that your local environment cannot run (for
example one that needs symbolic-link privilege) must be reported as such, not
removed. GitHub-hosted Windows CI is authoritative.

### Slice registration (LR-14 scope gate)

The LR-14 scope gate requires every commit of a pull request to belong to a
registered, reviewed slice. Use two commits:

1. the change itself (code, tests, docs);
2. a separate commit that only appends a `RegisteredSlices` entry to
   `tests/validate-local-router-lr14-scope.ps1`, with the full `Base` (the
   pull request's base commit) and `Tip` (commit 1) SHAs, the changed files as
   `Artifacts`, and one distinctive marker string per artifact.

Never edit or remove existing registrations. The repository's genesis handling
is described in [docs/OSS_GENESIS.md](docs/OSS_GENESIS.md).
