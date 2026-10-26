# Changelog

## 3.8.0 — 2026-08-23

- Added an in-window **模型健康驾驶舱** to the Desktop Controller.
- Provider cards now show local readiness for ChatGPT login, Alibaba Model Studio, OpenRouter, and Xiaomi MiMo without displaying API-key values.
- Added `installer/scripts/controller-health.ps1` as a LOCAL ONLY health snapshot helper: no provider HTTP call, no Responses request, no paid inference, and no real-time balance query.
- Model health labels now normalize controlled catalog states into **首选 / 官方 / 已验证 / 已批准 / 已配置·未实测 / 实验 / 额度受限**.
- The cockpit highlights operationally important models such as the account default, verified Qwen/DeepSeek routes, Ox Alpha experimental status, GLM credit limitation, MiMo credit limitation, and dynamically approved models.
- `额度受限` is explicitly a known catalog/runtime status rather than a live billing check; adding funds does not silently trigger a probe.
- Added **刷新健康状态** for zero-paid-inference refreshes while keeping the existing **详细健康检查** entry for full diagnostics and optional read-only catalog checks.
- Expanded Desktop Controller CI with runtime health mapping, provider/key readiness, secret non-disclosure, LOCAL_ONLY mode, and a guard against provider-network/inference calls in the cockpit helper.

## 3.7.1 — 2026-08-23

- Reframed the Desktop Controller's folder choice from a duplicate **project** concept to a lightweight **working directory** selector for each new Codex CLI session.
- Replaced the project-path textbox with an editable workspace combo that quick-lists Git repositories directly under `~/Projects` while still allowing any folder to be chosen manually.
- The quick list reads directory/Git metadata only; it does not open or index project source files merely to populate the selector.
- Stale saved non-Git locations such as the Desktop are no longer preferred over real Git workspaces at startup.
- Added `last_workspace` user-state persistence while retaining `last_project` as a backward-compatible state alias for existing installations.
- Kept Codex Desktop as the sole owner of its project/thread UI; the Controller only chooses the filesystem working directory and provider/model route for a fresh CLI session.
- Expanded Desktop Controller CI coverage for workspace semantics, Git-repository discovery, stale-location fallback, and removal of the old `ProjectPathBox`/“当前项目” UI concept.

## 3.7.0 — 2026-08-23

- Added a read-only Desktop Controller catalog merge between the repository-controlled `installer/model-catalog.json` and user-level `~/.codex/multimodel-manager/approved-models.json`.
- Dynamic models appear in the GUI only after the existing basic Responses probe reports `PASS` and the model has been explicitly approved; discovery alone never exposes or activates a model.
- Added `installer/scripts/controller-catalog.ps1` with fail-closed provider mapping, duplicate suppression, dynamic brand inference, and catalog-source metadata.
- Added **刷新模型目录** so newly approved models can appear without changing source code or restarting the Controller.
- Added direct Desktop Controller access to the existing **模型更新中心** while preserving explicit confirmation for paid probes and approval.
- Unsupported approved Provider routes remain hidden instead of being silently sent through a different Provider.
- Added deterministic CI coverage for approved-model merging, non-PASS filtering, unsupported-route filtering, source/status tagging, and dynamic brand inference.
- Removed the stale V3.3 label from the Model Update Center and kept installer/Skill copies synchronized.

## 3.6.1 — 2026-08-23

- Separated API Provider routing from model-brand presentation in the Desktop Controller.
- Added a four-level selector: **Provider → model brand → model version → reasoning effort**.
- Added explicit brand metadata to the controlled catalog so Alibaba Model Studio can host Qwen and DeepSeek models without making DeepSeek look like a Qwen sub-model.
- Kept Provider/model coupling unchanged: brand is display-only and cannot reroute requests.
- Persisted the last selected brand at user scope and added CI guards for Qwen/DeepSeek brand separation.

## 3.6.0 — 2026-08-23

- Added a real **Provider → model version → reasoning effort** selector to the Windows Desktop Controller.
- Added `installer/model-catalog.json` as the controlled UI catalog for ChatGPT/OpenAI, Alibaba Model Studio, OpenRouter, and Xiaomi MiMo routes.
- The Controller now passes the selected provider and model ID together to `launch-controller-model.ps1`; the dropdown is not display-only.
- Added explicit model choices for GPT-5.6 Sol/Terra/Luna, GPT-5.5/5.4/5.4 Mini, Qwen3 Coder Plus/Next, Qwen 3.8 Max, DeepSeek V4 Pro/Flash, Ox Alpha, GLM 5.3, and MiMo V2.5/V2.5 Pro.
- Added selectable `low`, `medium`, and `high` reasoning effort.
- Preserved one-click quick presets for the commonly used verified routes; presets now go through the same provider-aware selector path.
- Persisted the last provider/model/effort at user scope without storing API keys or project content.
- Expanded Desktop Controller CI validation to verify model-catalog integrity and provider/model coupling.

## 3.5.3 — 2026-08-23

- Changed Desktop and Start Menu shortcuts to launch through `wscript.exe` and `installer\LAUNCH_DESKTOP_CONTROLLER.vbs` instead of targeting the visible `.cmd` launcher.
- The hidden launcher starts PowerShell 7 in STA mode with window style `0`, so the WPF Controller opens without a PowerShell/Windows Terminal window.
- Kept `CODEX_DESKTOP_CONTROLLER.cmd` unchanged as a visible troubleshooting/debug entrypoint.
- Expanded shortcut CI validation to prevent regressions back to a visible CMD target.

## 3.5.2 — 2026-08-23

- Added `installer\INSTALL_DESKTOP_SHORTCUTS.cmd` for one-click creation/refresh of a Windows Desktop shortcut and Start Menu entry for the Desktop Controller.
- Added `installer\scripts\install-desktop-shortcuts.ps1`; shortcuts point back to the repository Controller launcher, so later `git pull` updates are picked up without copying app code or secrets to the Desktop.
- Added setup option **11** for shortcut installation and an opt-in shortcut refresh prompt when exiting setup.
- Kept shortcut creation user-scoped and non-destructive: no project files, Codex auth, API-key values, or Git worktrees are modified.
- Added dedicated CI validation for shortcut script syntax, target integrity, Start Menu/Desktop path usage, and destructive-Git exclusions.

## 3.5.1 — 2026-08-23

- Polished the Desktop Controller into a clearer software-style dashboard with a primary-model card, verified backup group, experimental/credit-needed badges, and softer Windows UI styling.
- Added user-level persistence for the **last launched model** alongside the existing last-project path.
- Added a visible “last launched” indicator so the operator can tell which provider/model route was used most recently.
- Kept the provider-aware **new-session-only** switching rule unchanged; no old cross-provider thread reuse was introduced.
- Expanded Controller CI validation to verify the new persisted-state behavior and XAML well-formedness.

## 3.5.0 — 2026-08-23

- Added **Codex Multi-Model Desktop Controller**, a lightweight Windows WPF GUI launched by `installer/CODEX_DESKTOP_CONTROLLER.cmd`.
- Added project-folder selection, persisted user-level last-project state, read-only Git branch/HEAD/worktree status, and a warning before launching from dirty worktrees.
- Added provider-aware model buttons for ChatGPT official, Qwen3 Coder Plus, DeepSeek V4 Pro, Ox Alpha, GLM 5.3, and MiMo V2.5 Pro.
- Every Controller model selection starts a **new Codex CLI session** instead of reusing a cross-provider Desktop thread, preventing the known model/provider mismatch pattern.
- Reused the existing Windows User environment-variable keys; the GUI never displays or writes API-key values into project files or Codex TOML.
- Reused the existing Git handoff snapshot before model launch and preserved the no-reset/no-clean/no-stash rule.
- Added Controller shortcuts for Health Check, handoff verification, provider setup, and the legacy command-line switcher.
- Added dedicated non-interactive CI validation for Controller entrypoint integrity, model routes, PowerShell syntax, and Git safety.

## 3.4.0 — 2026-08-22

- Added a one-click **Health Check** entrypoint plus Model Switcher option 13.
- Health Check diagnoses PowerShell/Codex/Git availability, ChatGPT login state, API-only login conflicts, Profile V2 leftovers, global custom-catalog leakage, provider configuration, user-scope API-key presence, Git handoff readiness, and custom-model metadata warnings without printing secrets.
- Added optional read-only OpenRouter `/models` validation to verify catalog reachability and whether `stealth/ox-alpha` is still present; no paid inference is executed.
- Added explicit `-Repair` mode. Manager-owned profile/catalog migrations stay backup-preserving, and disabling `forced_login_method = "api"` requires an explicit confirmation unless the caller deliberately passes `-Yes` for automation/tests.
- Health reports are written only under `~/.codex/multimodel-manager/reports/` and never inside project repositories.
- V3.4 intentionally reports unknown third-party/stealth model metadata as a warning instead of inventing context-window or capability values.
- Added a Windows CI runtime regression covering auth repair, Profile V2 migration, legacy catalog preservation, ChatGPT profile normalization, installer/Skill parity, and preservation of the user's old `models.json`.

## 3.3.7 — 2026-08-22

- Fixed legacy provider-specific `model_catalog_json` settings leaking globally into ChatGPT sessions and replacing `/model` with the old custom catalog.
- When a non-OpenAI global `model_provider` and `model_catalog_json` are detected, those root model settings are preserved in `~/.codex/legacy-codex-catalog.config.toml` and removed from global scope.
- The preserved legacy catalog remains launchable from Model Switcher option 8 and is intentionally not treated as a Manager-owned disposable profile.
- ChatGPT launch no longer hard-codes `gpt-5.6`; the profile keeps the OpenAI provider and reasoning preference while allowing Codex to select the official model actually supported by the signed-in ChatGPT account.
- Expanded Profile V2 CI coverage for legacy catalog isolation, ChatGPT account-model fallback, preservation of unrelated provider configuration, ownership boundaries, and idempotency.

## 3.3.6 — 2026-08-22

- Added compatibility with the current Codex Profile V2 format used by `codex --profile <name>`.
- Manager-owned `[profiles.*]` tables are migrated out of `~/.codex/config.toml` into dedicated `~/.codex/<name>.config.toml` files while shared `[model_providers.*]` definitions remain in the base config.
- Model Switcher now detects and migrates legacy Manager profiles before launch, fixing the `--profile ... cannot be used while config.toml contains legacy profile` startup error seen on Codex 0.149.0.
- Dynamic approved models are migrated to the same dedicated profile-file format.
- Setup refresh immediately performs the migration after regenerating Manager configuration, and Manager removal cleans up only profile files recorded in its ownership manifest.
- Added a dedicated Windows CI migration test covering fixed profiles, dynamic profiles, unrelated user-config preservation, ownership tracking, and idempotency.

## 3.3.5 — 2026-08-22

- Fixed Windows launches where a provider API key had been saved at User scope but an already-open terminal had not inherited the new variable, causing Codex to report `Missing environment variable` even though setup showed the key as configured.
- Model Switcher now hydrates known provider keys from Windows User scope into its current process before launching Codex; values are never printed or written to project/config files.
- Stealth/Ox Alpha launcher now explicitly passes the saved `OPENROUTER_API_KEY` into the Codex child process before invocation.
- Added CI regression guards for both fixed-provider switching and standalone stealth launches.

## 3.3.4 — 2026-08-22

- Fixed Git handoff collection/verification on PowerShell 7 by renaming the `GitText` parameter from automatic `$Args` to explicit `$GitArgs` and using named array binding.
- Added a guard that rejects empty Git invocations so handoff failures stop clearly instead of launching bare `git` and printing usage.
- Made handoff snapshots honor `CODEX_HOME`, keeping installer and Skill runtime behavior aligned with the rest of the manager.
- Added a real temporary-repository CI smoke test that runs the actual `collect-handoff.ps1` and `resume-handoff.ps1` scripts and verifies an unchanged repository round-trip.

## 3.3.3 — 2026-08-22

- Fixed setup option `0` so it terminates the outer setup loop instead of only leaving the `switch` block.
- Fixed Stealth Model Registry synchronization on PowerShell 7 by replacing the generic `List[object]` suspect collector with a native PowerShell array and an explicit `object[]` assignment before persisting `suspected_replacements`.
- Made `sync-stealth-registry.ps1` return to callers instead of exiting the host process, so it can be composed and tested safely.
- Added deterministic CI runtime regression coverage for setup exit behavior plus empty/non-empty stealth suspect-array persistence; no provider API, paid inference, network call, or user credential is used in the test.

## 3.3.2 — 2026-08-22

- Fixed PowerShell 7 runtime failures caused by assigning to `$home`, which collides case-insensitively with the read-only automatic `$HOME` variable.
- Renamed local Codex/manager home variables to explicit names such as `$codexHome` and `$managerHome` in setup, status, discovery, and shared runtime helpers.
- Added a dedicated CI guard that scans PowerShell AST assignments for accidental writes to `$HOME` and runtime-smoke-tests `Get-StatePath` under a temporary `CODEX_HOME`.

## 3.3.1 — 2026-08-22

- Fixed Windows setup/runtime failures caused by UTF-8 PowerShell scripts being launched with legacy Windows PowerShell 5.1 on some locales.
- All Windows `.cmd` entrypoints now require and launch **PowerShell 7 (`pwsh.exe`)**.
- Entry points show a clear `winget install --id Microsoft.PowerShell -e --source winget` instruction when PowerShell 7 is missing.
- Weekly scheduled discovery now uses `pwsh.exe` instead of `powershell.exe`.
- Skill command examples now use `pwsh` consistently.

## 3.3.0 — 2026-08-22

- Added a generic **Stealth Model Registry** for anonymous/stealth aliases.
- Added user-level alias state in `~/.codex/multimodel-manager/stealth-models.json` plus JSONL status/migration history.
- Seeded `Ox Alpha -> stealth/ox-alpha` as the first tracked stealth alias.
- Added read-only OpenRouter catalog sync that detects disappearance and records suspected replacements without auto-migrating.
- Added explicit reveal/migration recording with live model-ID validation and exact `MIGRATE` confirmation.
- Added generic alias-based launcher that prefers a confirmed live replacement, falls back to the still-live old ID, and stops when neither exists.
- Refactored Ox Alpha launch to use the generic stealth alias resolver while preserving the `OX` confirmation and Git handoff gate.
- Integrated stealth lifecycle sync into normal/scheduled model discovery without paid inference or Codex config mutation.
- Added `installer/STEALTH_MODEL_REGISTRY.cmd`, model-update-center access, docs, and dedicated CI validation.

## 3.2.0 — 2026-08-22

- Added guarded **Ox Alpha** experimental launch support through the existing OpenRouter Responses provider.
- Added `stealth/ox-alpha` catalog-presence verification before launch.
- Added explicit `OX` confirmation before starting the anonymous/stealth model.
- Added a dedicated Windows entrypoint: `installer/LAUNCH_OX_ALPHA_EXPERIMENTAL.cmd`.
- Added Ox Alpha to the normal model switcher without making it a default fallback.
- Added Git handoff preservation before launching Ox Alpha from a repository.
- Added `docs/OX_ALPHA.md` with current model ID, safety policy, and launch requirements.
- Added dedicated CI validation for the Ox Alpha integration.

## 3.1.0 — 2026-08-22

- Added GitHub Actions **Development Gate** CI for pull requests to `main`, pushes to `main`, and manual runs.
- Added `tests/validate-repo.ps1` as the canonical local/CI static validation entry point.
- Added PowerShell syntax validation for all repository `.ps1` files.
- Added repository/Skill/installer structure and entrypoint integrity checks.
- Added safety checks for destructive Git switching commands, force push, and legacy active `wire_api = "chat"` configuration.
- Added common committed-secret pattern checks and Codex auth/runtime-state tracking checks.
- Kept CI static and non-destructive: no paid inference, no user Codex config mutation, no external project access.

## 3.0.0 — 2026-08-22

- Added automatic model discovery from configured provider model-list endpoints.
- Added first-run baseline and later new-model diffing.
- Added candidate registry states.
- Added optional basic Responses and tool-calling probes.
- Added explicit approval before dynamic Codex profile registration.
- Added dynamic approved-model switching.
- Added optional weekly Windows discovery task.
- Kept discovery read-only with respect to Codex config and project repositories.

## 2.0.0 — 2026-08-22

- Added one-click Windows provider configuration.
- Added GPT-5.6-first multi-provider switching.
- Added Git handoff snapshots and verification.
- Added Codex Skill packaging.
- Added config backup and API-key environment-variable handling.
