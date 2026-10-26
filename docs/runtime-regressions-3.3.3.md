# Runtime regressions fixed in V3.3.3

This release fixes two Windows runtime issues found during real setup:

1. Setup option `0` now terminates the outer setup loop instead of only leaving the `switch` block.
2. Stealth Model Registry sync no longer persists a generic `List[object]` directly into `suspected_replacements`; it uses a native PowerShell array and explicit `object[]` normalization.

CI now runs `tests/validate-runtime-regressions.ps1`. It checks the setup exit guard, verifies the stealth sync source keeps the safe array implementation, and exercises the same property-persistence shape with both empty and non-empty suspect arrays. The test is deterministic and local: it does not call provider APIs, paid inference, or user credentials.
