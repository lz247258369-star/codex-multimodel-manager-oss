# ADR: Local Router Runtime Stack

Status: **Accepted (LR-1)**

Decision date: 2026-08-28

Scope: LR-1 Router Core Skeleton and Lifecycle. This ADR pins the implementation
stack for the Local Router runtime and is normative for LR-1. Later slices may
extend the stack only through a new ADR entry.

## Context

`LOCAL_ROUTER_RUNTIME_CONTRACTS.md` and `LOCAL_ROUTER_RUNTIME_ROADMAP.md` mandate a
language-neutral adapter contract with a planned C# + ASP.NET Core substrate, and
explicitly defer the exact SDK/runtime/package decision to the LR-1 ADR after
toolchain, license, Windows CI, deterministic build, single-file distribution,
cancellation, and SSE review.

LR-1 itself must remain a compileable/testable skeleton with **no network, no
config/state/secret access, and a default-disabled host that exits safely**.

## Decision

### .NET SDK (exact)

- Exact SDK: **10.0.400**.
- Pinned in `local-router/global.json` with `"rollForward": "disable"`.
- Rationale: .NET 10 is the current LTS (support through 2028-11-10). .NET 8 LTS
  ends 2026-11-10 and .NET 9 STS ended 2026-05-12; neither is suitable for a new
  runtime starting 2026-08.
- CI installs the identical SDK via `actions/setup-dotnet@v4` with
  `dotnet-version: 10.0.400`.
- Contributors install the same SDK with the official `dotnet-install.ps1`
  script (`-Channel 10.0`); the SDK is never committed to this repository.

### Target framework

- `net10.0` for every LR-1 project (`Router.Core`, `Router.Host`,
  `Router.Core.Tests`) via `local-router/Directory.Build.props`.

### Runtime strategy

- **Framework-dependent** for LR-1. The repository does not ship a runtime.
- LR-1 produces no publish artifact; `dotnet build` yields a normal
  framework-dependent apphost on Windows.
- Self-contained, trimming, and single-file packaging are explicitly deferred to
  LR-15 (see "Future single-file boundary" below).

### Package/version policy

- **Zero runtime NuGet dependencies** in `Router.Core` and `Router.Host` for
  LR-1. No ASP.NET Core, Kestrel, HTTP, or socket packages.
- Test-only packages are pinned to exact versions using central package
  management (`local-router/Directory.Packages.props`):

  | Package | Version |
  |---|---|
  | `Microsoft.NET.Test.Sdk` | 18.9.0 |
  | `xunit` | 2.9.3 |
  | `xunit.runner.visualstudio` | 4.0.0 |

- No floating versions (`-*`), no `Latest`/`*` ranges. NuGet lock files
  (`packages.lock.json`) are committed for deterministic restore.

### Windows CI

- Existing Development Gate runs on `windows-latest`.
- Additive LR-1 steps in `.github/workflows/ci.yml`: setup-dotnet (10.0.400,
  cache enabled), `dotnet restore`, `dotnet build -c Release --no-restore`, and
  `dotnet test -c Release --no-build` for `local-router/LocalRouter.sln`.
- CI stays non-destructive: no provider call, no user config/state mutation, no
  secret access, no network listener.

### Deterministic build

- `<Deterministic>true</Deterministic>`.
- `<ContinuousIntegrationBuild>true</ContinuousIntegrationBuild>` when `CI=true`.
- `<RestorePackagesWithLockFile>true</RestorePackagesWithLockFile>` with committed
  lock files.
- `<InvariantGlobalization>true</InvariantGlobalization>` so no locale-dependent
  behavior enters the skeleton.

### Nullable and analyzers/warnings

- `<Nullable>enable</Nullable>` for all projects.
- `<TreatWarningsAsErrors>true</TreatWarningsAsErrors>`.
- `<EnableNETAnalyzers>true</EnableNETAnalyzers>`,
  `<AnalysisLevel>latest-recommended</AnalysisLevel>`,
  `<CodeAnalysisTreatWarningsAsErrors>true</CodeAnalysisTreatWarningsAsErrors>`,
  and `<EnforceCodeStyleInBuild>true</EnforceCodeStyleInBuild>`.
- CA1707 (underscores in identifiers) is disabled in test projects because xUnit
  tests intentionally use snake_case method names; all other analyzer rules stay
  warnings-as-errors.
- Public LR-1 types carry XML documentation where behavior is non-obvious.

### Test framework

- xUnit 2.9.3 on Microsoft.NET.Test.Sdk 18.9.0 with the xUnit Visual Studio
  runner 4.0.0.
- Tests are unit-level. A fake clock drives UUIDv7 generation; the disabled-host
  proof launches `Router.Host.exe` as a real child process and asserts a fast,
  clean exit with no listener startup.

### Cancellation

- `CancellationToken` flows through `RequestContext` and
  `CancellationCoordinator`; the coordinator links caller and shutdown tokens.
- Cancellation is idempotent and never maps to retry (`RouterError` with
  `retryable=false`, code `cancelled`).
- Request terminalization is compare-and-set: an already committed completion or
  failure wins over a late cancellation.

### Future SSE compatibility

- LR-1 adds no streaming transport and no HTTP packages, keeping the LR-3
  ingress boundary explicit.
- Types needed by future SSE work (cancellation-aware `RequestContext`, stable
  `RouterError` serialization, typed correlation IDs) are in place now; streaming
  framing, backpressure, and Kestrel hosting arrive in LR-3.

### Future single-file boundary

- LR-1 deliberately keeps `PublishSingleFile=false` and framework-dependent
  output. Single-file/self-contained/trimming are LR-15 packaging decisions that
  require security/SBOM and clean-machine tests.
- LR-1 rollback is removing `local-router/` plus the CI steps; Direct Mode is
  untouched.

## Consequences

- The skeleton is deterministic and reviewable with no hidden toolchain.
- Every contributor/CI machine must provide SDK 10.0.400.
- Later slices inherit the pinned stack; any version change requires a new ADR
  entry.
- LR-2+ scope (config/state/secret/ingress/provider code) remains absent from
  this PR.
