# Codex Multi-Model Manager V4 Visual Console

V4 adds a dark, card-based Windows WPF interface on top of the existing Multi-Model Manager runtime. It is a real controller, not a mockup or generated image.

## Launch

Visible troubleshooting launcher:

```powershell
.\installer\CODEX_VISUAL_CONSOLE.cmd
```

Silent GUI launcher:

```text
installer\LAUNCH_VISUAL_CONSOLE.vbs
```

The classic V3.x controller remains available through `CODEX_DESKTOP_CONTROLLER.cmd` and from the V4 dashboard as a rollback/fallback UI.

## V4.0 pages

### Dashboard

- selected model hero card;
- working-directory selector;
- read-only Git branch / HEAD / CLEAN-DIRTY status;
- card-based model matrix;
- local Provider health cards;
- one-click fresh Codex session launch;
- shortcuts to model discovery, Stealth Registry, and detailed health check.

### Models

- Provider selector;
- model-brand selector;
- model-ID selector;
- reasoning-effort selector;
- controlled catalog plus explicitly approved dynamic models;
- click a model card to route the selector to the correct Provider/model pair.

### Providers

Provider readiness is local-only. The page reports whether the expected Provider config exists and whether the expected user/process environment-variable key exists. Secret values are never shown.

### Stealth Registry

The page surfaces the existing Ox Alpha lifecycle and opens the existing Stealth Registry tools. It does not infer anonymous-model identity or perform automatic migration.

### Tools & Safety

The visual UI delegates to the existing gated Health Check, Handoff verification, Model Update Center, Provider setup, and command-line switcher.

## Safety invariants

V4 keeps the existing Manager safety boundaries:

- no automatic `git reset`, `git clean`, or `git stash`;
- dirty Git worktrees require launch confirmation;
- model discovery does not silently approve or activate models;
- Provider health refresh performs no paid inference;
- API-key values are never displayed by the Visual Console;
- third-party Provider switches always launch a fresh Codex CLI session;
- user UI state is stored under `~/.codex/multimodel-manager/visual-console-state.json`, never inside project repositories.

## Architecture

```text
Visual Console (WPF)
        |
        +-- controller-catalog.ps1
        +-- controller-health.ps1
        +-- launch-controller-model.ps1
        +-- health-check.ps1
        +-- model-update-center.ps1
        +-- stealth-model-center.ps1
        +-- resume-handoff.ps1
        +-- setup.ps1
```

V4 intentionally reuses the existing tested runtime rather than duplicating Provider, model-discovery, Stealth, or Git-handoff logic.
