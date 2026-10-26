# LR-15 PR10B — Router Host lifecycle controller

`installer/scripts/router-lifecycle.ps1` is the operator-facing lifecycle
surface: **Status**, **Start** and **Graceful Stop** for the Local Router Host.
It composes existing boundaries only — the PR10A Windows startup gate, the
DSR6 `RouterHostBootstrap` lifecycle and cancellation contract, the Owner Record
plus `OwnershipVerifier` identity rule, `RouterStateStore` durability and the
PR9 Host release verifier. No module is re-implemented and no installation
authority is added.

## Exit codes (controller)

| Code | Meaning |
|---|---|
| 0 | the action succeeded (a status was determined; Start verified a complete managed READY; Stop completed) |
| 2 | usage error: an absolute `-CodexHome` (or `CODEX_HOME`) is required |
| 4 | refused: a required capability is unavailable (Start without a verified release; Stop without a usable control capability) |
| 5 | refused: the observed lifecycle does not allow the action |
| 6 | Start did not reach a verified managed READY (early exit, missing control capability, or timeout) |
| 7 | Stop was accepted but its completion could not be proven (the process is never killed) |
| 8 | the Host refused the control request (authentication or request shape) |

The Host has its own exit-code namespace (`RouterHostBootstrap`): `0` clean stop,
`2` configuration/ownership/startup failure and a failed `STOPPED` write, `3` an
unrecovered access-control cleanup, `4` a Windows Host that reached durable READY
but could not publish and protect its lifecycle control capability, `130` a
cancelled startup. A Host `4` is reported by the controller as
`start_failed_control_channel_unavailable`.

## Status semantics

Status is strictly read-only and prefers `UNKNOWN` over any unprovable answer. A
persisted terminal state is **history**, not a current stop proof: a fresh Host
can be inside its pre-owner startup window while the durable state still reads
`STOPPED`, and no read-only query has an independent current proof of "nothing
is running". A terminal state is therefore reported as `UNKNOWN` with the
historical state attached as evidence, and a confident state is reported only
for a **verified live owner**.

Process presence is decided three ways: `present` (identity matches PID + start
ticks + fingerprint), `absent` (that process id does not exist) and
`unverifiable` (access denied, start time unavailable, or an identity mismatch
from PID reuse). Only `present` supports an active state, and only `absent`
supports a crash. `unverifiable` is never converted into an exit or a stop.

| Situation | Reported state (reason) |
|---|---|
| no user config, or `mode != router`, or `local_router.enabled != true` | `DISABLED` (`default_and_no_user_config` / `user_config_not_enabled`) |
| user config unreadable | `UNKNOWN` (`user_config_unreadable`) |
| runtime state missing/unreadable/unknown lifecycle | `UNKNOWN` (`runtime_state_missing` / `runtime_state_unreadable` / `runtime_lifecycle_unknown`) |
| owner record unreadable, invalid or fingerprint-inconsistent | `UNKNOWN` (the specific reason) |
| owner record present, identity **verified live**, durable state active | that lifecycle (`owner_identity_verified`) |
| owner record present, identity verified live, durable state `STOPPED` | `UNKNOWN` (`live_process_with_terminal_state`) |
| owner record present, process verified absent, durable state non-terminal | `FAILED` (`owner_process_exited_without_terminal_state`) |
| owner record present, process verified absent, durable state `STOPPED` | `UNKNOWN` (`terminal_state_without_current_stop_proof`) |
| no owner record, durable state `STOPPED` | `UNKNOWN` (`terminal_state_without_owner_record`), evidence carries `historical_lifecycle = STOPPED` |
| no owner record, durable state active | `UNKNOWN` (`active_state_without_owner`) |
| process identity unverifiable (access, PID reuse, unavailable start time) | `UNKNOWN` (the specific reason) |
| any read failure | `UNKNOWN` (`status_read_error`) |

Anti-misreport guarantees: a missing, stale, unreadable or forged owner record,
a reused PID, an unreadable process identity, a redirected path, a corrupt state
file or a read failure can never be reported as `STOPPED`. Every confident
conclusion names its proof source (`current_state_proof` for an active state,
`historical_lifecycle` plus `current_stop_proof = none` for history).

Status writes nothing: the validator hashes the isolated Codex home before and
after a query and requires it to be byte-for-byte unchanged. No provider key,
token or `auth.json` is read, no path or SID is printed, and no PR10A ACL,
junction or reparse artefact is touched.

## Start semantics

Start refuses (`4`) without a PR9 verified Host release identity (release root,
external manifest digest, package digest, version, source commit) and refuses
(`5`) when Router Mode is not enabled, when the durable state or owner record is
unreadable, when the recorded owner cannot be attributed, or when a verified
owner is already running. A verified-absent (stale/crashed) owner record is
startable: the Host's own stale-owner recovery archives it and no process is
killed or reused.

Success requires **all** of the following, otherwise Start reports `6` with a
distinct reason and never kills anything:

1. the PR9 release verified against the supplied identities;
2. the spawned process identity (PID + start ticks + fingerprint) matches;
3. durable `READY` belongs to that exact process;
4. the control endpoint exists and its identity matches that owner and the
   durable config generation;
5. the endpoint carries the required current-user-only access control;
6. a **live pipe instance** of exactly the endpoint's random name exists — a
   stale JSON file is not a capability;
7. the Host is still running;
8. therefore the control capability is usable, not merely present.

The Host is spawned only from the verified release root, with `CODEX_HOME`
pinned to the requested home. It inherits this operator's environment — Provider
secret *references* stay environment references and the controller never reads
or prints a value — and its console output is written by the child's own file
handles. A controller never terminates a spawned Host, not even after a timeout:
it reports the incomplete state instead.

## Stop semantics

Stop is authenticated and graceful, and it never kills an unknown process:

1. the durable facts are read directly (enablement never gates a stop);
2. the owner identity must be verified live (PID + ticks + fingerprint); an
   unverifiable, foreign, absent or unreadable owner is refused (`5`);
3. the published control capability must match that owner and config generation,
   carry a **real current-user-only** access control and be backed by a live pipe
   instance (`4` with the specific reason otherwise). The token is a credential,
   so it is not enough that broad *write* is absent: an allow-grant to any
   identity other than the current user (or the local SYSTEM account) is refused
   whether it is read or write — `control_endpoint_acl_inherits_foreign_access`
   (inheritance never removed), `control_endpoint_acl_foreign_identity`
   (any foreign allow-grant), `control_endpoint_acl_unresolved_identity`,
   `control_endpoint_acl_unresolved_user` or `control_endpoint_acl_unreadable`;
4. the single fixed-shape request is sent; a Host-side refusal maps to `8`;
5. completion is then **proven**, not assumed. Exit code `0` requires:
   - the target Host accepted the request;
   - the process bound to the verified identity was confirmed **exited**. Only
     two outcomes are evidence of an exit: `WaitForExit` returned true on the
     handle whose identity was verified immediately before waiting
     (`wait_for_exit_signalled`), or the process id no longer exists
     (`process_id_absent`, the documented "Process with an Id of N is not
     running" failure). Every other outcome is non-success: a timeout is
     `running`, and an unreadable identity, an unreadable start time, a failed
     wait or **any other exception — including a generic
     `InvalidOperationException` — is `unverifiable`** and never converted into an
     exit;
   - the durable runtime state was re-read and is `STOPPED`;
   - **this** owner record was archived: the archived file under
     `<quarantine>/<stamp>-<id>/router.pid.json` must match the live record's
     SHA-256 **and** its PID/ticks/fingerprint, which is exactly how
     `RouterStateStore.QuarantineAsync` archives it (a byte copy, no on-disk
     receipt), so another historical archive cannot stand in;
   - no live owner record remains;
   - no unexplained identity contradiction was observed: if the verified identity
     is still present after a confirmed exit, the Stop is
     `stop_incomplete_identity_contradiction`.

Any missing proof returns non-zero (`7`) with a specific reason
(`stop_incomplete_process_still_running`, `..._process_exit_unverified`,
`..._identity_contradiction`, `..._terminal_state_unproven`,
`..._owner_archive_unproven`) and leaves the process alone; the evidence names
the exit proof and its detail (`process_exit_proof`, `process_exit_evidence`,
`post_exit_presence`). A repeated Stop without a target owner record is refused
(`5`), never reported as a completed stop.

The controller source is pinned by the validator: it contains no `.Kill(`,
`Stop-Process`, `taskkill`, `Remove-Item`, `Set-Content`, `Add-Content` or
`Out-File`, it never mentions `auth.json`, and it never claims the PR8 lease
surface.

## Host-local control channel

The Host publishes the capability *after* its durable READY commit and withdraws
it before the durable stop begins, so an authenticated stop can never reach the
startup-abort path and no controller can address a Host that is already
stopping. Publication order is a security contract:

1. the capability is written into a **randomly named private temporary file** in
   the same pinned runtime directory, created with the current-user-only
   security descriptor **at creation** (`FileSystemAclExtensions.Create`), so the
   token never exists in a file another principal could open — not even for an
   instant;
2. the protection is verified (`FileSecurityStatus.Protected`, no broad write
   grant);
3. a stale plain-file capability of a previous instance is replaced and the file
   is published by an **atomic rename** inside the pinned directory (which PR10A
   makes unreplaceable). Anything else — a directory, a locked path, a
   failed/replaced descriptor, a failed write — publishes nothing and aborts the
   channel.

The controller's credential check on the endpoint file is identity based, not
rights based: the descriptor must be protected, and every allow-grant must
belong to the current user (or the local SYSTEM account). A read-only grant to
`Users`, `Authenticated Users`, `Everyone` or any other identity is treated as a
capability leak and refused, because reading the file is enough to stop the
router.

The pipe is created with `PipeOptions.CurrentUserOnly`, so another user cannot
open it even if the file leaked; the request shape is fixed
(`schema_version`/`action`/`token` only), the token comparison is constant-time,
the request size is bounded and connect/read are bounded by timeouts. The
listener accepts exactly one connection, answers it, waits (bounded) until the
peer consumed the answer — disconnecting a named pipe discards unread data, so
the answer is delivered before the shutdown it triggered can tear the pipe down —
and then never serves a second request. It executes no command, signals no
process and writes no user configuration; no token, private path, SID,
exception message or Provider key is ever logged.

## Deliberately BLOCKED or bounded (not claimed as done)

1. **PR8 stopped-lease.** `installer/scripts/router-uninstall-safety.cs` still
   requires `IRouterLifecycleGuard.AcquireStopped(installRoot, installationId)`
   with an `IStoppedRouterLease.AssertStopped()` proof. That needs a trusted
   `InstallationId ↔ InstallRoot ↔ verified Host binary ↔ RuntimeDirectory ↔ Host
   process identity` binding which does not exist (PR10A provides a
   runtime-directory kernel identity only, and PR9 remains
   `installation_permitted=false`). No lease is produced, no `AcquireStopped`
   success is fabricated, and uninstall keeps failing closed.
2. **Remote or cross-user control.** The endpoint is loopback-host-local and
   current-user-only by construction. The pipe DACL is applied by
   `PipeOptions.CurrentUserOnly`; the controller verifies the endpoint file's
   access control and the live pipe instance, and does not itself query the pipe
   descriptor. No network control plane, service control or privilege escalation
   exists.
3. **Same-user threat model.** As documented for PR10A, the boundary assumes a
   trusted current user; it does not defend against hostile code running as that
   same SID or privileged administrators.
4. **Windows only.** The startup gate, the protected endpoint file and the pipe
   identity boundary are Windows behaviour. Other platforms have no Windows
   lifecycle capability (and establish no Windows lifecycle evidence); their
   enabled Host path already fails closed earlier on owner-record protection.
5. **Fault-injection limits.** A failed access-control restore (PR10A) and a
   process-state read failure that only occurs after acceptance cannot be forced
   from outside; they are covered by the classification contract and the
   achievable native cases below, never claimed as executed.

## Validation

`tests/validate-router-host-lifecycle.ps1` runs, in one throw-away sandbox
hierarchy:

- status cases A–J plus `STATUS-1` (historical `STOPPED` only → `UNKNOWN`),
  `STATUS-2` (reused PID → `UNKNOWN`), `STATUS-3` (unreadable identity →
  `UNKNOWN`), and the read-only byte-for-byte proof;
- the static safety contract and the PR8 boundary declaration;
- refusal cases `L`–`R`, each with a real child process that must still be alive;
- `STOP-1` (accepted request, process still running → `7`, process untouched) and
  `STOP-2` (unverifiable process state → refused, never an exit);
- on Windows: a real PR9 verified release published from a temporary clone of
  this checkout, then `START-3`/`STOP-5` (managed READY and the proven graceful
  stop with a decoy archive present), `START-1` (capability path occupied →
  `6`, no unmanaged Host left), `START-2` (a capability that does not belong to
  the started owner → `6`, no unmanaged Host left), `START-4` (two concurrent
  Starts → at most one success, at most one Host, and the survivor is still
  stoppable), `STOP-3` (durable `STOPPED` write blocked → `7`, owner record not
  archived) and `STOP-4` (owner archive unprovable → `7`, live record preserved).

`local-router/tests/Router.Core.Tests/Host/HostLifecycleControlTests.cs` pins the
in-process Host behaviour: real READY publishes a bound, protected, live
capability; an authenticated stop persists `STOPPED` and archives the owner; a
foreign token is refused and never kills the Host; malformed requests are
refused; an unverifiable capability protection is never published; and a Windows
Host that cannot publish its capability stops through the cleanup path with
`ControlChannelUnavailableExitCode` instead of serving unmanaged.
