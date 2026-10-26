# LR-15 PR10A — Windows Host startup gate

This is runtime startup exclusion, not installation identity or a stopped lease.
Router remains disabled by default. Disabled Bootstrap exits before acquiring
the gate, creating a runtime directory, resolving secrets or binding ingress.
No Direct Mode, Desktop, V4, Provider or configuration mutation behavior changes.

## Boundary and ordering

Every enabled `RouterHostBootstrap.RunAsync` acquires
`WindowsRouterStartupGate` before observability composition, Owner Record load,
local-token resolution and ingress bind. A `using` declaration retains it through
STARTING, READY, STOPPING, request drain, durable state writes and owner archival,
including startup cancellation and failure returns. The existing
`RouterLifecycle`, schema-v1 Owner Record and graceful shutdown are reused.
Path-provider strings are snapshotted once; the existing `router.pid.json` and
`router.state.json` must share the same absolute runtime directory. A mutable
provider or changing environment cannot redirect later ownership writes away
from the coordination directory. Mismatched paths fail before gate creation.

The restricted runtime identity is:

```
current Windows user SID + local NTFS volume serial + runtime directory file ID
```

The directory is the parent of `OwnerRecordPath`. It is opened with native
`CreateFileW(OPEN_REPARSE_POINT | BACKUP_SEMANTICS)`. Its ancestors are opened
in order, final handle paths are checked, and all directory handles deny
delete/rename sharing for the gate's lifetime. Drive-root parents are refused.
Every pinned directory shares read/write but never delete: the missing
`FILE_SHARE_DELETE` is what refuses renaming or deleting the pinned directory,
while the shared write class is what lets the Host publish owner/READY/STOPPED
atomically inside the runtime leaf. The metadata-write class that a reparse
replacement needs is refused separately; see FIX4.

### FIX1: native directory share access

The failed Windows run 38133414655 showed a successful `GENERIC_WRITE` open
against the original metadata-only pin (`READ_CONTROL | FILE_READ_ATTRIBUTES`).
Those rights alone do not establish the directory read access required for
Windows share-access accounting. FIX1 additionally requests `FILE_LIST_DIRECTORY`
on every pinned directory (including reopening a newly created runtime leaf).
Lack of that permission is a startup refusal, never a fallback to weaker rights.

Write-handle refusal is only one assertion, not proof of identity immutability.
The isolated native fixture has a working `FSCTL_SET_REPARSE_POINT` Junction
positive control, reproduces the metadata-only/write-handle behavior, attempts
reparse mutation with generic-write, write-attributes and zero-access handles,
and attempts leaf/parent rename followed by Junction replacement. Before/after
NTFS volume/file IDs and reparse attributes must match; unverifiable identity
fails the test. Target sentinel bytes and actual Host Owner Record hashes must
remain intact. Native errors, rename exceptions and outcomes are printed;
evidence is retained without recursive cleanup. The attacks run both against
the empty coordinated directory and actual STARTING/READY Hosts. Windows CI
must complete the remaining concurrency, shutdown, crash and ACL tests too.
Linux compilation or disabled-path checks cannot certify these native guarantees.

### FIX2: Host regression diagnosis and sandbox contract

Windows run 38134567217 reported Core 337 PASS / 71 FAIL, predominantly
READY/startup-tail/shutdown waits. This is a Windows regression, not evidence
of a Linux limitation. The unavailable run's per-Host exit/refusal details have
not yet been independently obtained, so inherited ACLs are a source-supported
candidate, not a confirmed explanation for all 71 failures.

The Core GUID sandbox previously inherited the runner temp ACL, unlike the
native fixture's private sandbox. It now supplies a current-SID-owned protected
DACL, with inheritable FullControl for that SID, when creating the Windows test
directory. Existing directories are not deliberately adopted or repaired.
Production ACL checks, directory read access and sharing are unchanged.
No share-write or share-delete relaxation is justified by a READY timeout alone.

Gate refusal diagnostics include a fixed stage, exception type and integer
Win32 error, without paths, SIDs, SDDL, exception messages or request data.
The repeated lifecycle tests now detect an early Host task exit (exit code or
sanitized exception type/HResult) instead of hiding it behind readiness waits.
Original timeouts, 20-repeat assertions, ownership and drain checks remain.
Windows CI first reuses the existing Release build for three one-case original
Host lifecycle tests and the complete native gate fixture, then runs the full
solution tests and Canonical Gate. The native fixture records an actual Host
outcome under the original inherited temp ACL: a trusted directory must start;
refusal is accepted only with evidence of an unsafe parent ACL and the matching
refusal stage. Private STARTING/READY Hosts must still commit/archive state and
survive all original native identity attacks. Require `STARTUP_GATE_NATIVE PASS`
and a successful complete Windows Gate before acceptance.

Default profile-derived directories and custom `CODEX_HOME` remain subject to
the same trust checks. No real home/config is inspected or repaired. Custom
broadly writable directories must refuse; normal profile compatibility remains
pending isolated Windows evidence, not an assumption about runner permissions.

### FIX3: exact persistence failure evidence

Windows run 38136740142 reported smoke 2 PASS / 3 FAIL, native 3 PASS / 1 FAIL
before termination, and Core 339 PASS / 74 FAIL. `state_write_failed` and exit 2
do not identify the failing file operation. They cover both Owner Record atomic
write/security protection and READY persistence. Before FIX3, directory/temp
creation was outside the atomic writer's error normalization, while write,
existence check, move and replace failures were merged into one error. File ACL
failures were silently reduced to `Unknown`.

FIX3 adds fixed target roles, operation names, exception categories, HRESULT and
native Win32 codes, without paths, SIDs, SDDL, exception messages or file content.
Host diagnostics identify `owner_record`, `ready_state` or `stopped_state`.
Archive read/create/copy/delete failures are reported and still rethrown. A failed
STOPPED save returns exit 2 and retains ownership instead of archiving the Owner
Record and claiming a clean durable stop. Previous good state remains available
for verified recovery. No stopped/uninstall lease is granted.

The probe now publishes the actual Host exit before its own assertions. A
post-secret-resolution persistence failure is no longer confused with an early
gate refusal. Early stdout termination prints the actual child exit and only
whitelisted content-free stderr diagnostics. `Win32Exception` is included.

Before actual Host scenarios, a second Windows process exercises directory/temp
creation, real write-through writes, atomic move and replace, file ACL read/set,
production Owner Record write, READY/STOPPED save and readback, and byte-verified
Owner Record archival while the first process retains the production gate.
It compares gate-created runtime directories with pre-existing runtime
directories inheriting the private parent's OI/CI ACL. Both must pass under the
same strict sharing; failure is never accepted as a successful control. A third
isolated case uses `DefaultRouterPathProvider` with a GUID `CODEX_HOME` and the
production nested directory layout. No real profile is inspected or repaired.
Empty-directory Junction/reparse/replacement attacks still run before creating
scratch files, and all actual STARTING/READY attacks remain required.

A real Host fault case injects a Win32 sharing violation only at STOPPED atomic
replacement. It requires exit 2, unchanged READY and Owner bytes, no premature
Owner archival, temp cleanup, closed ingress and released startup coordination.
The injected error is a regression control, not evidence of the native root
cause. Native code 32 means sharing violation; 5 means access denied. Neither is
claimed as the observed code from run 38136740142.

Strict production directory access/sharing and ACL validation remain unchanged.
The exact Windows cause, default-layout compatibility and simultaneous normal
persistence/anti-replacement guarantees remain **BLOCKED** until the new Windows
run completes all cases with `STARTUP_GATE_NATIVE PASS` and the full Development
Gate succeeds. Linux diagnostic tests cannot close this acceptance boundary.

Relative paths, UNC/device paths, traversal,
ADS, reserved names, reparse points, spelling aliases and non-fixed/non-NTFS
volumes are rejected. No link is followed to choose a coordination identity.

Only the final runtime directory may be created, after pinning its existing
parent; creation supplies a current-user-owned private DACL atomically. Existing
directories require a current-user, SYSTEM or local Administrators owner and
must not grant write/delete/ACL mutation to untrusted principals. This preserves
legacy directories created by elevated Windows tokens whose default owner is
Administrators. SYSTEM and local Administrators are trusted for directory
administration; the kernel object still requires the exact current user as
owner. Access denial, unreadable security or unsupported
ACLs fail closed. Existing directories/ACLs are never repaired or overwritten.
An enabled startup refusal may leave its newly created empty private directory;
there is no recursive cleanup or adoption of unknown user files.

The physical identity hashes to a versioned `Global\` mutex name, so casing and
session aliases do not split the boundary. `CreateMutexExW` supplies an explicit
current-user DACL. An existing kernel object is accepted only after handle-based
owner/DACL validation; unknown ownership or broad access is refused. Acquisition
is nonblocking: a second process fails with `startup_gate_busy` before ownership
or listener side effects. No PID file or cached lifecycle grants coordination.

### FIX4: share-write pinning plus an explicit metadata-write guard

Windows CI run 38138998110 (PR #102 attempt 2) failed before READY with
`operation=MoveFile target=owner_record hresult=80070020 native=32
category=sharing_violation` and `Host exited before startup barrier exit_code=2`.

Measured cause on Windows (isolated native probes, same share/access parameters
as production): Windows resolves a child-file rename or replace by opening its
**parent directory** for the data-write class, so a `FILE_SHARE_READ`-only handle
on the file's own directory fails every atomic publication inside it with
`ERROR_SHARING_VIOLATION(32)`. The same measurements showed the other half of the
mechanism: it is the missing `FILE_SHARE_DELETE` — not `FILE_SHARE_WRITE` — that
refuses renaming or deleting the pinned directory itself, and
`FILE_WRITE_ATTRIBUTES`, the access `FSCTL_SET_REPARSE_POINT` actually needs, is
**not** part of `FILE_SHARE_WRITE`, so a write-attributes open could still set a
Junction on the pinned runtime directory.

The pin now:

- shares `FILE_SHARE_READ | FILE_SHARE_WRITE` and never `FILE_SHARE_DELETE` on
  every pinned directory: child publication works, and leaf/parent rename or
  delete stay refused with `win32=32` (verified by the rename/replace attacks);
- applies an explicit **metadata-write guard** — a `DENY` ACE for
  `FILE_WRITE_ATTRIBUTES | FILE_WRITE_EA` to the current user — on the runtime
  directory for the coordination lifetime, which refuses the reparse primitive
  with `ACCESS_DENIED(5)`. Creating, renaming and replacing child files needs the
  data-write class, not the metadata-write class, so persistence is unaffected;
- applies that guard **only after this process owns the kernel mutex**, restores
  the captured access control on release, and removes a residue left by a crashed
  predecessor before capturing its own restore state, so the guard heals itself
  instead of accumulating. A process that loses the coordination race never
  touches the ACL;
- keeps every existing refusal unchanged: the guard runs after `AssertSecurity`,
  does not relax identity, filename, path or ACL checks, and is restored before
  the directory handles are released.

Refusals are therefore per access class: the data-write class is refused by
sharing, the metadata-write class by the guard. The native fixture reports both
(`DIRECTORY_WRITE_REFUSED generic=… metadata=…`) and still fails if either open
succeeds, so weakening one class cannot silently pass.

Residual risk, stated explicitly: while the Host runs, the runtime directory's
metadata-write right is denied to the current user, and if the process is killed
between apply and restore the deny ACE remains until the next gate acquisition
removes it. Deleting or renaming the directory is unaffected (it needs delete
rights), so a residue never blocks cleanup or uninstall.

### FIX5: effective ACL denial and guard/mutex lifecycle

Windows CI run 38186623694 (PR #102 attempt 3) reported
`STARTUP_GATE_SUMMARY PASS=83 FAIL=2` with the fixture assertion
`Insufficient directory permissions refuse coordination` failing: the Host started
successfully although the fixture had added an explicit `ReadAttributes` deny.

Measured cause (real Windows, current user, DACL-only writes): Windows does not
enforce that deny for the access the gate requests. `FILE_READ_ATTRIBUTES` is
granted implicitly whenever any other access is granted, so a deny on
read-attributes alone cannot refuse the pin. The access map, measured per single
right with an explicit deny on the runtime directory:

| Denied right | gate pin open (`0x00020081`) | write open (`0x2`) | child create |
|---|---|---|---|
| `FILE_LIST_DIRECTORY`/`FILE_READ_DATA` (0x1) | **refused (5)** | allowed | ok |
| `FILE_WRITE_DATA`/`FILE_ADD_FILE` (0x2) | allowed | **refused (5)** | **fails (5)** |
| `FILE_APPEND_DATA`/`FILE_ADD_SUBDIRECTORY` (0x4) | allowed | allowed | ok |
| `FILE_READ_ATTRIBUTES` (0x80) | allowed | allowed | ok |
| `FILE_WRITE_ATTRIBUTES` (0x100) | allowed | allowed | ok |
| `DELETE` (0x10000) | allowed | allowed | ok |
| `READ_CONTROL` (0x20000) | allowed | allowed | ok |
| `WRITE_DAC` (0x40000) | allowed | allowed | ok |

Two consequences, both implemented:

1. **The gate refuses an effective deny.** `AssertSecurity` now inspects explicit
   `AccessDenied` ACEs as well and fails closed when a deny that applies to this
   process identity (the user SID or a SID carried by its token) removes any right
   the runtime requires — `FILE_LIST_DIRECTORY`, `FILE_WRITE_DATA/FILE_ADD_FILE`
   or `READ_CONTROL`. The metadata-write class is deliberately excluded: the guard
   denies it on purpose, and a deny on rename/delete rights is not evidence of an
   unusable runtime directory because directory sharing already refuses those.
2. **The fixture asserts effectiveness before it asserts refusal.** A deny on
   `FILE_READ_ATTRIBUTES` alone is no longer treated as "insufficient
   permissions": each deny scenario proves with a real native open that the
   coordination access mask is refused (`GATE_OPEN refused=True native=5`), and
   the state-write scenario proves that an effective write deny refuses
   acquisition. All existing refusal assertions are unchanged; the ineffective
   deny is replaced by an effective one instead of being accepted or deleted.

Guard and mutex lifecycle (same run): the earlier shape installed the guard on the
caller thread after the mutex was acquired and restored it during `Dispose`, after
`_ownerThread.Join()` had already let the mutex go. That is now owned entirely by
the coordination thread:

1. the thread acquires the kernel mutex;
2. it installs the metadata-write guard (a losing process never reaches this step,
   so its residue cleanup can never remove the live winner's deny ACE);
3. it reports acquisition, then waits for release;
4. on release it restores the captured access control **while still holding the
   mutex**, and records a restore failure instead of claiming a clean shutdown;
5. only then does it release the mutex;
6. the caller closes the mutex handle and the pinned directory handles afterwards.

If the guard cannot be installed, the thread reports the failure, releases the
mutex and exits, so the constructor's join is bounded by a fixed amount of work
and cannot deadlock. Measured limits on fault injection, reported honestly: a
read-only share mode does not block `WRITE_DAC`/`WRITE_OWNER` opens (only the
data-write class), and an owner keeps implicit DACL-write rights, so a guard
install/restore failure cannot be forced from outside; the fixtures therefore
verify the observable contract (fail closed, no leaked mutex, no deadlock, guard
residue healed, exact DACL restored on a normal release) rather than the injected
exception itself.

Local fixture limits, stated explicitly: creating a directory symbolic link needs
`SeCreateSymbolicLinkPrivilege`, so a non-elevated session prints
`SKIPPED SymbolicLink runtime fixture: symbolic link creation requires an elevated
session` and continues; the elevated Development Gate runner executes it.

#### Cleanup-failure exit semantics

A shutdown that cannot restore the runtime directory access control is not a clean
stop, so the host must not report one. `WindowsRouterStartupGate.Dispose` releases
every resource first (the coordination thread has restored what it could and
released the kernel mutex; this object then closes the mutex and directory
handles) and only then raises `RouterStartupGateException` with the fixed label
`startup_gate_cleanup_failed` and stage `metadata_restore`. Because a `using`
declaration disposes during unwinding, that exception replaces the pending return
value, so no early `return` can slip a cleanup failure through as exit code 0.

The host's existing coordination boundary reports it with cleanup-specific wording
(`enabled Host shutdown cleanup failed`) and returns its own non-zero code
`RouterHostBootstrap.CleanupFailedExitCode = 3`. The other codes keep their
meaning: `0` normal stop (including `STOPPED` persisted and owner archived), `2`
configuration/ownership/startup failure and a failed `STOPPED` write, `130`
cancellation. Dispose stays idempotent, so a repeated call is a no-op and never
releases coordination or the ACL twice.

Fault-injection limit, reported honestly: an access-control restore failure cannot
be induced from outside on Windows (measured: share modes do not cover
`WRITE_DAC`/`WRITE_OWNER`, and an owner keeps implicit DACL-write rights), so this
branch is pinned by the source-level contract assertions in
`tests/validate-router-host-startup-gate.ps1` plus the runtime assertions that a
normal release restores the exact DACL, a refused acquisition leaks no mutex and a
repeated `Dispose` is a no-op. No production environment-variable back door was
added for it.

## Ownership across async and exit

A dedicated background thread performs native `WaitForSingleObject`, holds the
mutex while the Host awaits asynchronous work, and performs `ReleaseMutex` on
that same thread. Disposal signals and joins the owner thread before closing
the kernel and directory handles. Repeated disposal is harmless. There is no
thread-pool mutex ownership, cross-thread release or timed release after READY.

The kernel releases mutex ownership and all file handles on process exit.
An abandoned mutex can be acquired for a **new startup**; this never asserts
STOPPED or uninstall safety. Bootstrap still validates any existing Owner Record
using PID, start ticks and fingerprint, refuses live/foreign identities and
archives only verified stale ownership. Corrupt records preserve the existing
fail-closed behavior. No unknown process is killed.

This boundary assumes a trusted current user, executable and OS administration.
It does not defend against hostile code running as that same SID or privileged
administrators replacing the executable/security policy. Different runtime
directories or users are different restricted runtime identities. Port binding
and the existing owner checks remain additional conflict protections.

## PR8 / PR9 boundary

Neither `IRouterLifecycleGuard` nor `IStoppedRouterLease` is implemented or
returned by PR10A. A free startup mutex is not proof that an installed product
is stopped. Installation UUID, trusted PR6 product provenance and independently
anchored PR9 Host identity are not bound here. PR9 remains
`installation_permitted=false`; PR7/PR8 schemas and contracts remain unchanged.
Future production lifecycle work must add authenticated stop control and trusted
installation binding before granting any uninstall lease. No full manager,
production stop/kill, upgrade/rollback or combined V1 installer is introduced.

## Validation and CI cost

After the existing Release build:

```powershell
./tests/validate-router-host-startup-gate.ps1 -RepositoryRoot $PWD -UseExistingBuild
```

Without `-UseExistingBuild` the standalone validator incrementally builds Host
first. The canonical validator reuses the Development Gate build. It compiles
only `StartupGateProbe.cs` and the existing deterministic blocking-state fixture
with SDK 10.0.400; no extra restore or Host publish is introduced.

On Windows, real isolated child processes exercise native single/racing
acquisition, simultaneous actual Bootstrap startup, STARTING and READY losers,
retained ownership, graceful/cancelled exit, archived stale owner after a crash,
permission/unsafe-ACL refusal, case aliases, junctions, symlinks, pinned-ancestor
replacement refusal and invalid paths. STARTING uses the existing held READY
write, not Sleep. Only explicitly created Process objects are terminated to
simulate crash or clean up a timed-out fixture. Every child environment is
cleared and rebuilt with a temporary home; Host uses Fake secrets and Fake
responses and makes no Provider requests. Unknown user bytes are retained.
GUID-named temporary evidence directories are retained rather than recursively
deleted. Failure is fatal; native PASS is emitted only when all assertions pass.

Linux executes compilation, disabled Bootstrap and unsupported-platform refusal
only, and emits `STARTUP_GATE_NATIVE NOT_RUN`. It cannot validate Windows
security descriptors, native mutexes or rename semantics. Acceptance requires
the actual Windows Development Gate; this document makes no CI PASS claim.
The existing 20-minute CI limit and all previous tests remain unchanged; the
fixture adds bounded process waits and no repeated full publication.

Previous Linux failures are individually classified in
[PR10 Linux failure evidence](PR10_LINUX_FAILURE_CLASSIFICATION.md). Unknown
causes remain unknown; no baseline assertion or unrelated module was changed.

Rollback is an ordinary reviewed revert of this feature and its exact scope
registration. No installed files or user configurations need rewriting.
