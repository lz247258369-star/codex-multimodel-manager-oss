# LR-15 PR8 — Safe uninstall executor

PR8 adds `Uninstall-RouterOwnedPackage` to the existing ownership module. PR6
provenance and the PR7 schema-v1 manifest/public read-only planner remain the
authority. It does not implement upgrades, upgrade rollback, Host packaging,
Host lifecycle controls, provider changes or user-environment auto-uninstall.

## Authorization and lifecycle prerequisites

The command requires `PackageRoot`, `InstallRoot`, `ExpectedPackageSha256` and
`ExpectedInstallationId`. Without `-Execute` it returns a read-only `DryRun`
result and creates no progress file. `-Execute -WhatIf` is also read-only.
Actual execution requires both `-Execute` and ShouldProcess approval.
Load the module from trusted code outside the installation, and keep the trusted
package outside it too. Self-hosted code/source within the deletion tree is
refused, so a partial uninstall cannot delete the verifier needed for recovery.

Execution additionally requires a trusted caller implementation of
`CodexManager.Installation.IRouterLifecycleGuard`. Its `AcquireStopped(root, id)`
must verify the exact installation is stopped and return an `IStoppedRouterLease`
which inhibits Host starts until disposed. `AssertStopped()` must throw on a
running Host, lost lease or unknown status. PR8 checks it repeatedly, including
immediately before the Windows disposition operation; it never kills a process.
A boolean, PID-file absence or previously saved status is not accepted.

**No production lifecycle coordinator ships in this slice.** Existing Host
startup does not participate in an uninstall lease. Consequently a standalone
operator without a real stop/start coordinator cannot safely execute and is
refused; the command must not be advertised as a one-click user uninstaller.
The caller adapter is trusted executable integration code, not user-editable
proof. Fake adapters are used only by the isolated tests. Implementing Host
lifecycle integration is a separate authorized task, not a PR8 bypass flag.

## File deletion boundary

Every invocation re-verifies the trusted PR6 package and PR7 ownership schema,
UUID, root, digest and exact ledger. Unsafe roots, Windows device/ADS/traversal
paths, case aliases, unknown entries and any linked subtree fail closed.
All unowned files and all directories are preserved. The command does not use
recursive deletion, wildcards or prefix-based ownership.

The production backend is **Windows only**. It captures volume/file identity,
then opens each owned file exclusively with `OPEN_REPARSE_POINT` and DELETE
access. It rejects directories, hard links and reparse points, checks ancestors
and the final handle path, hashes the open bytes, and checks the original file
identity again. `SetFileInformationByHandle(FileDispositionInfo)` deletes the
verified object when its handle closes; it does not re-resolve a pathname after
hashing. A competing exclusive handle or permission failure stops the sequence.

PR7 is a content ledger, not a historical file-ID attestation. A same-byte
replacement *before* the initial verified snapshot is indistinguishable from
the installed bytes. Replacements after the snapshot are detected by file ID.
As with PR6/PR7, a malicious caller with write access to all artifacts is outside
the trust boundary. This narrows filesystem races; it is not a claim of absolute
race freedom against a privileged attacker or a dishonest lifecycle adapter.

## Partial deletion, recovery and repeat invocation

The executor creates `router-uninstall-progress.json` with CreateNew and holds
an exclusive stream during execution. A pre-existing file is never adopted by
default. The schema-v1 receipt binds root, UUID, package digest, original PR7
manifest and its digest, and an exact ordered file ledger with original IDs.
The ownership manifest is the final ledger entry.

Each entry transitions `ready -> pending -> done`. The pending intention is
flushed to disk **before** deletion. The command aborts immediately on any
error, retains the progress receipt and does not force remaining operations.
The exception's `Data['progress_path']` and `Data['progress_sha256']` provide
the last on-disk evidence. Retain the digest externally in the trusted calling
workflow; do not authenticate an arbitrary receipt by hashing itself later.

A retry requires `ExpectedProgressSha256`. It re-verifies the original PR7
schema against the trusted package, allows absent files only for an ordered
authenticated `done`/single `pending` prefix, and checks every remaining file.
A pending absent file represents a delete completed before its completion
record and can be marked done. A pending present file must still match both
hash and original identity before retrying. A done path that reappears is
preserved and blocks the retry. Unknown states, modified receipts, unexpected
absence and out-of-order entries refuse recovery.

A completed authenticated repeat performs no deletion and preserves recreated
user paths by refusing them. The completion receipt is deliberately retained,
and empty installation directories are not removed. PR7 still refuses installing
over those directories; PR8 does not implement reinstall/old-version cleanup.

Journal writes use flush-to-disk but are not transactionally atomic across a
power loss. Torn/corrupt journals fail closed and require separate manual
inspection; there is no force or journal-repair switch. This limitation is
explicit rather than inferring lost ownership. Code rollback is ordinary revert;
it cannot restore already deleted payloads and does not perform upgrade rollback.

## Validation

Run `pwsh -NoProfile -File tests/validate-router-safe-uninstall.ps1`; it is also
wired into `tests/validate-repo.ps1`, so the existing Windows Development Gate
executes it. Fixtures use synthetic PR6 packages, PR7 installs, temporary user
sentinels and Fake lifecycle leases. On Windows the actual native deletion,
junction, hardlink and exclusive-handle behavior is tested. On Linux only the
private deletion backend is replaced with a Fake for orchestration/recovery
coverage. No Linux result substitutes for actual Windows CI.

The PR7 regression and Direct Mode/profile regressions remain required. The
known `MiMoContractTests.Idle_timeout_is_normalized` timing flake is independent;
record an occurrence separately, do not weaken it or silently skip assertions.
