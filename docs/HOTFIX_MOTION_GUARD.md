# V4 Motion Startup Guard

Motion Design System v1 remains in the repository but is temporarily disabled in the production startup path unless `CODEX_MM_ENABLE_MOTION_V1=1` is explicitly set.

Reason: the hidden VBS launcher can hide a PowerShell exception that occurs before the WPF window reaches `ShowDialog()`. Optional motion must not be able to prevent the manager from opening.

Default behavior after this hotfix:
- V4 opens with the previously validated Commercial UI Polish.
- Model routing, pricing, providers, Desktop Chat routing, Git state, and credentials are unchanged.
- Motion v1 can still be exercised explicitly while a full-window startup smoke test is added.
