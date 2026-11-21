# OSS workflow tools

Developer tools that reduce repeated work without changing what is verified.
They never change product code, the CI workflow, the LR-14 gate, the
registration list or Git configuration. Run them with PowerShell 7 from the
repository root (set `DOTNET_ROOT`/`PATH` if your .NET SDK is not on `PATH`).

| Tool | Purpose |
|---|---|
| `Invoke-TieredVerification.ps1` | Recommends and runs a verification level (L1–L4) for the real change set and writes a receipt. |
| `Test-CommitIdentityPrivacy.ps1` | Read-only pre-push gate for commit and local Git identities. |
| `New-Lr14RegistrationCandidate.ps1` | Proposes LR-14 registration data for review. It never registers or approves. |
| `New-EvidenceReport.ps1` | Builds an acceptance-evidence report from Git, receipts and live gate runs. |
| `tests/Test-OssWorkflowTools.ps1` | Automated tests for all of the above. |

## Verification levels

| Level | Runs | Use |
|---|---|---|
| L1 | `git diff --check`, parsing of changed PowerShell/JSON, identity privacy | documentation-only changes |
| L2 | L1 + build and tests of affected .NET projects (real project graph), validators that reference the changed paths, these tool tests when the tools change, the LR-14 gate | one module |
| L3 | L1 + every step of `.github/workflows/ci.yml`, locally | CI, build, SDK, gate, installer, Skill, Host, unknown or cross-module changes |
| L4 | L3 on a clean checkout of the `origin/main` tip | after merge / release |

The policy sets a minimum level and a lower `-Level` is refused. L1/L2 are
partial results and L3/L4 are local reproductions. **No local receipt is a
GitHub CI result**; the Development Gate on the pull request and on `main`
stays required. SKIP and BLOCKED are never PASS.

- A change counts as L2 only when real tests cover it (a project in the .NET
  project graph with a test project, an existing validator, a fixture some
  validator references, the tool tests). Anything else is upgraded to L3.
- L3/L4 also run the tests that `ci.yml` does not run but L2 would (the tool
  tests and selected validators missing from `ci.yml`), so a higher level never
  runs less.
- The LR-14 gate file counts as a registration (L2) only when the change is a
  single insertion of new, pure-data entries (quoted constants only, exactly
  `Name`/`Base`/`Tip`/`Artifacts`/`Markers`) plus comments; every existing line
  must stay byte-identical. Anything else is a gate change (L3).
- If HEAD, the tree, the working tree, the environment, the base reference, the
  merge base or the verification tool changes while the checks run, the result
  is BLOCKED and no PASS receipt is written.

```powershell
pwsh tools/oss-workflow/Invoke-TieredVerification.ps1 -PlanOnly
pwsh tools/oss-workflow/Invoke-TieredVerification.ps1            # recommended level
pwsh tools/oss-workflow/Invoke-TieredVerification.ps1 -ReuseReceipt   # L1 only
pwsh tools/oss-workflow/Invoke-TieredVerification.ps1 -ListReceipts   # history
```

Receipts are written to `.git/oss-workflow/receipts/` (never tracked).
**Reuse applies to L1 static checks only.** At L2, L3 and L4 every check is
executed again even when an identical earlier PASS receipt exists; that receipt
is recorded in the new one as `historical_receipt` (history only) and every
check is marked `reused: false`. `-ListReceipts` lists stored receipts and
whether each still describes the current state; it verifies nothing. The
evidence report marks each check as executed in this run or reused L1 history.

An L1 receipt is reused only when commit, tree, uncommitted changes, base, environment (OS,
pwsh and dotnet executables, Git, resolved and installed .NET SDKs, build
environment variables, runner image, machine, identity verdicts), tool version,
level and planned checks are all identical and its self-hash is intact. Values
that could identify a person or a path are stored as verdict labels or hashes
only. Reuse is refused when the environment cannot be determined reliably, and
the identity privacy check is always re-run live: a reused receipt can never
turn a failing identity into a PASS.

## Before pushing

```powershell
pwsh tools/oss-workflow/Test-CommitIdentityPrivacy.ps1     # exit 0 required
```

Only the identities in `approved-identities.json` are accepted. Output shows
labels, never names or addresses. The existing manual privacy review stays in
place; a CI check after a push cannot undo a leak, so this runs before pushing.

## LR-14 registration candidate

```powershell
pwsh tools/oss-workflow/New-Lr14RegistrationCandidate.ps1 -Tip <implementation commit> -Name <SLICE-NAME>
```

Pass reviewed markers with `-MarkersFile markers.json` (`{"path": "marker"}`);
each one must occur in the file at the tip, and a marker that is not part of an
added line is flagged. The output is review data only
(`status: CANDIDATE_NOT_REGISTERED`). Append the
entry through the normal two-commit registration and let the LR-14 gate and the
pull-request review check it. Markers are real added lines; when none
qualifies the marker is left empty for the reviewer.

## Evidence report

```powershell
pwsh tools/oss-workflow/New-EvidenceReport.ps1 -OutFile evidence.md
```
