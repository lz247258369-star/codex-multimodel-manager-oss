# Installer

Windows entry points for configuring and running Codex Multi-Model Manager.

Recommended order:

1. `ONE_CLICK_SETUP.cmd`
2. `CODEX_MODEL_SWITCHER.cmd`
3. `MODEL_UPDATE_CENTER.cmd` when checking or approving new models

`INSTALL_SKILL_ONLY.cmd` installs only the Skill payload from `../skill/codex-multimodel-manager/`.

The installer stores API keys only in Windows user environment variables and keeps runtime state under `~/.codex/`.
