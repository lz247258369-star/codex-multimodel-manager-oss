# Codex Multi-Model Desktop Controller

The Desktop Controller is a lightweight Windows GUI layered on top of Codex Multi-Model Manager. It does not patch or replace the official Codex Desktop application.

## Why it exists

Codex Desktop can change the visible model inside a thread without reliably changing the provider that created that thread. Reusing an old DeepSeek/Qwen/OpenRouter thread after selecting an OpenAI model can therefore send the new model ID to the old provider.

The Controller avoids that failure mode by always launching a **new Codex CLI session** for a selected provider/model pair.

## Launch

From the repository root:

```powershell
.\installer\CODEX_DESKTOP_CONTROLLER.cmd
```

The visible CMD launcher is kept for troubleshooting. Normal Desktop/Start Menu shortcuts use `LAUNCH_DESKTOP_CONTROLLER.vbs` through `wscript.exe`, so the GUI opens without a terminal window.

Requirements:

- Windows
- PowerShell 7 (`pwsh.exe`)
- Codex CLI
- Existing Multi-Model Manager provider setup

## Install to Desktop / Start Menu

```powershell
.\installer\INSTALL_DESKTOP_SHORTCUTS.cmd
```

This creates user-scoped Desktop and Start Menu shortcuts pointing back to the repository. Later `git pull` updates are therefore picked up without copying app code or API keys to the Desktop.

## V3.8 local model health cockpit

V3.8 adds a health cockpit directly inside the main Controller window. It is designed for the common question: **which route/model is ready before I launch it?**

The cockpit intentionally uses a **LOCAL ONLY** policy. Refreshing it does not call a model, does not send a Responses request, does not query provider billing APIs, and does not reveal API-key values.

Provider cards are derived from local evidence:

- **OpenAI / ChatGPT**: `codex login status` is read locally;
- **Alibaba Model Studio**: checks that `[model_providers.mm_modelstudio]` exists and that `CODEX_DASHSCOPE_API_KEY` exists at Process/User scope;
- **OpenRouter**: checks `[model_providers.mm_openrouter]` plus `OPENROUTER_API_KEY`;
- **Xiaomi MiMo**: checks `[model_providers.mm_mimo]` plus `MIMO_API_KEY`.

Only existence/readiness is shown. Secret values are never copied into the GUI or health snapshot.

Model cards come from the controlled catalog/approved registry status already used by the selector:

- `recommended` → **首选**;
- `official` → **官方**;
- `verified` → **已验证**;
- `approved` → **已批准**;
- `configured` → **已配置·未实测**;
- `experimental` → **实验**;
- `credit` → **额度受限**.

The main cockpit highlights the models that matter operationally: recommended, verified, explicitly approved, experimental, and known credit-limited routes. The selected-model detail line still exposes the underlying catalog status for every model.

### What “额度受限” means

`额度受限` is **not a live balance check**. It records a known runtime condition in the controlled catalog, such as a previous provider response that required additional balance/credits. The health cockpit deliberately does not spend tokens merely to see whether that condition has changed.

If you later add credit and want a real inference check, use the existing explicit probe/launch flow. Paid probes remain confirmation-gated.

### Detailed health check remains available

The **详细健康检查** button still opens the existing full `health-check.ps1` diagnostics. That path can perform the existing optional read-only OpenRouter `/models` catalog check, write a user-level JSON report, and offer explicit repair mode when requested. It remains separate from the zero-paid-inference cockpit refresh.

## V3.7.1 workspace selector boundary

The Controller does **not** create or manage a second project system. Codex Desktop remains responsible for its own project list, threads, pull requests, sites, scheduled tasks, and plugins.

The Controller only needs one directory value: the filesystem **working directory for the new Codex CLI session**.

The launch flow is therefore:

1. **Working directory**
2. **Route provider**
3. **Model brand**
4. **Model ID / version**
5. **Reasoning effort** (`low`, `medium`, `high`)
6. start a fresh Codex session

The working-directory control is an editable combo box rather than a project manager. At startup it builds a small quick list by checking immediate child directories under:

```text
~/Projects
```

Only Git metadata is inspected to decide whether a directory belongs in the quick list. Project source files are not opened or indexed merely to populate the selector.

A user can still choose any folder manually with **选择文件夹**. Non-Git folders remain valid Codex working directories; they simply do not get branch/HEAD/worktree status.

### Startup selection

V3.7.1 prevents a stale Desktop folder from behaving like a remembered Codex project:

- the saved `last_workspace` is preferred only when it is a Git repository;
- old `last_project` state remains readable for migration compatibility, but is treated the same way;
- a current Git working directory is preferred next;
- then the first detected Git repository under `~/Projects` is used;
- only if no Git repository is available does the Controller fall back to the Projects root or the user home directory.

This keeps Controller scope narrow: it chooses where a new CLI session starts, while Codex itself continues to own project/thread organization.

## V3.7 controlled + approved model catalog

The GUI catalog has two safe sources:

- `installer/model-catalog.json`: repository-controlled fixed models;
- `~/.codex/multimodel-manager/approved-models.json`: user-level models that already passed the basic Responses probe and were explicitly approved by the user.

`installer/scripts/controller-catalog.ps1` merges those sources in memory. It does **not** write user runtime state back to Git and it does not call any provider API.

The Controller has a **刷新模型目录** button. After a model is approved in the Model Update Center, click that button and the model can appear without changing source code or restarting the Controller.

The Controller also has a **模型更新中心** button. Discovery remains read-only; paid Responses/tool probes and model approval continue to require the existing explicit confirmation flow.

### Fail-closed rules

A dynamic record is shown only when all of these are true:

- it is present in `approved-models.json`;
- `basic_probe` is `PASS`;
- its provider maps to a Provider route already supported by the Desktop Controller;
- the model ID is non-empty.

Unsupported approved providers are not silently routed through another provider. For example, an approved xAI or Groq model stays out of the Desktop selector until that route is explicitly supported by the Controller.

If a dynamic approved model has the same model ID as a fixed controlled entry, the fixed entry remains the canonical UI item and is marked internally as registry-approved instead of being duplicated.

### Dynamic brand inference

Approved models receive a UI brand from their ID/display name. Known families include Qwen, DeepSeek, GLM, MiMo, Grok, Claude, Gemini, Kimi, MiniMax, OpenAI, and Stealth. Unknown approved families are grouped under **已批准新模型**.

Brand classification is display-only. It never changes the Provider used for the request.

## Provider vs brand

Provider is the API route. Brand is the model family.

Example:

```text
Alibaba Model Studio (provider route)
├─ Qwen (brand)
│  ├─ Qwen3 Coder Plus
│  ├─ Qwen 3.8 Max
│  └─ Qwen3 Coder Next
└─ DeepSeek (brand)
   ├─ DeepSeek V4 Pro
   └─ DeepSeek V4 Flash
```

DeepSeek models hosted by Alibaba Model Studio therefore remain on the Alibaba provider route even though they are shown under the DeepSeek brand.

## Fixed controlled catalog

Current fixed catalog includes:

- **OpenAI / ChatGPT** → brand **OpenAI**: account default, GPT-5.6 Sol, GPT-5.6 Terra, GPT-5.6 Luna, GPT-5.5, GPT-5.4, GPT-5.4 Mini.
- **Alibaba Model Studio** → brands **Qwen** and **DeepSeek**: Qwen3 Coder Plus, Qwen 3.8 Max, Qwen3 Coder Next, DeepSeek V4 Pro, DeepSeek V4 Flash.
- **OpenRouter** → brands **Stealth** and **GLM**: Ox Alpha and GLM 5.3.
- **Xiaomi MiMo** → brand **MiMo**: MiMo V2.5 Pro and MiMo V2.5.

The fixed catalog stays intentionally small. Automatic discovery does not dump hundreds of provider models into the GUI.

Quick-preset buttons remain available for the commonly used routes and use the same provider-aware launcher path.

## Safety behavior

Before launching a model session, the Controller:

1. resolves the selected working directory;
2. checks Git status read-only when that directory is a Git repository;
3. warns before launching from a dirty worktree;
4. never runs `git reset`, `git clean`, or `git stash`;
5. sends **provider + model ID + reasoning effort** to the launcher as one route;
6. launches a fresh PowerShell/Codex process in the selected working directory;
7. lets the existing handoff script snapshot repo/branch/HEAD/status before the model starts.

A dirty worktree is not modified or blocked automatically. The user decides whether to continue.

Provider API keys remain in Windows User environment variables and are never displayed by the GUI.

## Important limitation

The Controller does **not** inject third-party models into the official Codex Desktop model dropdown. It is a provider-aware launcher that starts new Codex CLI sessions, which is the reliable path while cross-provider thread switching in the official Desktop UI remains unsafe.

## User-level state

The Controller stores lightweight UI state under:

```text
~/.codex/multimodel-manager/controller-state.json
```

Current fields include:

- last selected working-directory path (`last_workspace`);
- legacy-compatible `last_project` alias for existing installations;
- last selected/launched provider;
- last selected model brand;
- last selected/launched model ID and label;
- last reasoning effort;
- state save timestamp.

Approved model registry state is read from:

```text
~/.codex/multimodel-manager/approved-models.json
```

No API keys, auth tokens, project source files, or Git credentials are stored in the Controller state.
