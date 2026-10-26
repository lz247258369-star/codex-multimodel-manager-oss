# Codex Desktop provider route for Ox Alpha

This feature lets Codex Desktop use the same local OpenRouter route that already works in Codex CLI, while keeping the official application binary and model picker untouched.

## Verified behavior

On 2026-08-24 the route was validated on a real Windows Codex Desktop installation:

- the Desktop app restarted normally;
- a new Desktop conversation reported the custom route;
- the UI showed a custom model state instead of the ordinary OpenAI selection state;
- the lower-left route indicator showed OpenRouter activity;
- Ox Alpha responded successfully in the new Desktop conversation.

The official model dropdown can still list only official OpenAI model names. The feature changes the backend provider/model route, not the official dropdown contents.

## V4 Visual Console integration

The V4 Visual Console exposes two separate concepts:

- **启动新 Codex 会话** — launches the selected model as a fresh Codex CLI session;
- **切换桌面 Chat → OX** — prepares Codex Desktop to use `stealth/ox-alpha` through `mm_openrouter` after an explicit confirmation.

The console also exposes **恢复桌面 ChatGPT**, which restores the exact pre-OX Desktop configuration saved by the Manager.

Switching the Desktop route still requires a full Codex Desktop restart and a new conversation. Existing Desktop conversations are not treated as hot-swappable model sessions.

## Manual activation fallback

If the Visual Console is unavailable, run:

```text
installer/ACTIVATE_OX_DESKTOP_EXPERIMENTAL.cmd
```

The route tool:

1. requires the existing Multi-Model Manager OpenRouter setup;
2. requires `OPENROUTER_API_KEY` from the current process or Windows user environment;
3. requires explicit `OX` confirmation when used manually;
4. backs up `~/.codex/config.toml` and the existing `~/.codex/.env` when present;
5. ensures the managed `mm_openrouter` provider definition exists;
6. copies the OpenRouter key into local `~/.codex/.env` without printing it;
7. sets the top-level Desktop default route to:
   - `model = "stealth/ox-alpha"`
   - `model_provider = "mm_openrouter"`
   - `model_reasoning_effort = "high"`
8. records the original backup location in `~/.codex/multimodel-manager/desktop-route-state.json`.

Repeated activation while the OX route is already active is idempotent: it does **not** rotate or replace the original rollback backup.

After activation, **fully exit Codex Desktop**, reopen it, and create a **new session**.

## Restore the previous Desktop configuration

Use the V4 **恢复桌面 ChatGPT** button or run:

```text
installer/RESTORE_CHATGPT_DESKTOP.cmd
```

The restore path copies back the exact `config.toml` backup created before the first activation and restores the previous `.env` state. Repeated restore is safe. Then fully exit/reopen Codex Desktop and start a new session.

## Safety boundaries

- no patching or binary modification of the official Codex Desktop app;
- no attempt to inject Ox Alpha into the official model dropdown;
- no project Git reset, stash, clean, force push, or project-file mutation;
- no API key committed to Git or written into `config.toml`;
- key value is never printed;
- exact pre-experiment Codex configuration is backed up for rollback;
- repeated OX activation preserves the first rollback point;
- activation performs no paid inference by itself.

## Operational rule

Treat a Desktop provider/model change as a new session boundary:

1. switch or restore the Desktop route;
2. fully exit Codex Desktop;
3. reopen Codex Desktop;
4. create a new conversation.

This keeps conversation state, tool state, and model routing from being mixed across different providers.
