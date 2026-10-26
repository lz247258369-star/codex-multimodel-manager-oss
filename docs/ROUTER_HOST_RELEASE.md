# LR-15 PR9 — Router Host release packaging

This is an independent compiled **Host component**, not a complete V1 product
installer, signed release or upgrade package. PR6 source package schema-v1,
PR7 ownership and PR8 uninstall contracts are unchanged. No Provider, routing,
Desktop, user configuration, Host lifecycle controller or model capability is
added. Building/verifying never starts a service or reads Provider credentials.

## Build and verify

Use a trusted, clean Git checkout at its root and an explicit full HEAD SHA.
Install the pinned .NET SDK **10.0.400** and PowerShell 7. The existing output
parent must be outside the source checkout and outside Codex user directories.

```powershell
$receipt = & pwsh -NoProfile -File installer/scripts/build-router-host-release.ps1 `
  -SourceRoot C:\isolated\source -SourceCommit '<trusted-40-hex-HEAD>' `
  -OutputRoot C:\isolated\releases -Version 3.8.0 | ConvertFrom-Json
```

Retain the receipt in the trusted build/delivery channel, separate from the
artifact. Verification requires **external** expected identities; do not read
the package's manifest and use its own asserted hashes as verification inputs.

```powershell
& pwsh -NoProfile -File installer/scripts/build-router-host-release.ps1 `
  -Verify -VerifyTarget C:\isolated\releases\router-host-3.8.0-win-x64-<commit8> `
  -Version 3.8.0 -SourceCommit '<trusted-40-hex-commit>' `
  -ExpectedManifestSha256 '<externally-retained-manifest-sha256>' `
  -ExpectedPackageSha256 '<externally-retained-content-sha256>'
```

The module also exports `New-RouterHostRelease` and
`Get-VerifiedRouterHostRelease` for structured callers. The CLI exits 0 on
success and 6 on refusal. Only `win-x64`, framework-dependent, three-part
numeric versions are supported. Version is stamped into the Host assembly by
publish properties; production project files are not changed.

## Build provenance and dependency boundary

The builder rejects dirty sources and a non-HEAD commit claim. It checks Git
tree entry modes, paths and case collisions before archiving only production
`local-router/src`, the two Directory props, global.json, defaults and the
model catalog from that commit. No working-tree code, tests, source credentials,
untracked state, `.git`, bin or obj is copied into the published artifact.

A unique temporary source/build directory and a unique output staging directory
are created. Portable restore first uses the checked-in locks with
`--locked-mode`. The current production dependency graph consists exclusively
of Project references. In isolated lock copies only, the builder adds an empty
`net10.0/win-x64` target, then performs RID restore in locked mode. It refuses
external Package dependencies or unreviewed lock targets rather than silently
resolving new versions. RID restore/publish must leave the derived locks unchanged.
SDK targeting/apphost packs come from the pinned SDK toolchain. Extending this
policy to external runtime packages requires a separately reviewed lock design.

Publish uses Release, `--no-restore`, explicit win-x64 and self-contained=false,
apphost=true, single-file=false, no PDBs and LatestPatch roll-forward. The source
checkout's project/locks remain untouched. All actual runtime DLLs must be
referenced by the dependency manifest, with no extra test/native/cache assets.

The output has this shape (32 payload files in the current production graph):

```text
router-host-3.8.0-win-x64-<commit8>/
  Router.Host.exe
  Router.Host.dll
  Router.<existing production component>.dll
  Router.Host.deps.json
  Router.Host.runtimeconfig.json
  model-catalog.json
  config/router.defaults.json
  router-host-release-manifest.json
```

The final directory is created by a directory rename only after verification.
An existing target is refused, including unknown files. No output directory is
recursively deleted. Build work and failed staging are deliberately retained;
exceptions expose their paths in `Data['build_work']`/`Data['release_stage']`.
Inspect these exact generated directories separately; there is no automatic
cleanup or force-overwrite flag. Running from a protected source/output directory
and trusting the selected commit, SDK and build agent are caller prerequisites.
This is content integrity, not a claim of protection against a privileged
concurrent writer or reproducibility across arbitrary machines.

## Host manifest schema-v1 and trust

`router-host-release-manifest.json` records:

- `schema_version`, product=`codex-multimodel-manager`, component=`Router.Host`;
- `version`, full `source_commit`, target_runtime=`win-x64`;
- deployment_mode=`framework-dependent`, entry_file=`Router.Host.exe`;
- `file_count` and `files` with exact relative path, byte size and SHA256;
- `package_sha256` over ordinal-sorted `path:size:sha256` lines with final LF;
- `runtime_prerequisites`: net10.0, x64, Microsoft.NETCore.App and
  Microsoft.AspNetCore.App, minimum 10.0.0, LatestPatch, supported Windows.

The returned manifest SHA256 binds **all metadata and the content ledger**. The
payload digest excludes the manifest to avoid a circular hash; the external
manifest digest anchors it. Both hashes, expected version, RID and source commit
are required by the independent verifier. Manifest identity/field types, entry
PE32+/AMD64 identity, Host managed assembly/version, deps graph, runtimeconfig
framework requirements and Router-disabled defaults are checked anew. Unsafe
paths, Windows names/ADS, case collisions, links/junctions, unknown files and
unknown empty directories refuse verification.

Hashes are **not code signing or publisher authentication**. A caller who trusts
a digest from the attacker-controlled artifact has provided no trust anchor.
No public release is uploaded and no signature/third-party attestation is claimed.

## Runtime and isolated Windows acceptance

Execution requires Windows x64 supported by .NET 10, with both .NET Runtime 10
and ASP.NET Core Runtime 10 x64 installed (the ASP.NET Core runtime bundle
includes the base runtime). LatestPatch permits compatible installed 10.0 patches,
not automatic major-version substitution. SDK/build requirements are separate
from end-user runtime requirements.

`tests/validate-router-host-release.ps1` clones a real committed source into a
temporary directory, cross-publishes and exercises negative integrity/provenance
cases. It is wired into the canonical Development Gate. On Windows it directly
executes the **verified published Router.Host.exe**, with an empty temporary
CODEX_HOME/cwd and a cleared child environment containing no Provider keys/tokens.
It requires exit 0, the exact DISABLED marker, empty stderr and no generated
config/owner/runtime files. A timeout fails and terminates only that known test
child, never an existing service or unknown process.

The existing Windows DSR6 Fake secret-resolver/port tests in the full .NET CI
gate prove that the disabled bootstrap does not resolve secrets or bind a
listener; the packaged-process smoke tests the real entry and file deployment.
Exit/empty state is not advertised as a packet trace. No real Provider request,
paid inference, real user home or lifecycle lease is used. Linux can verify the
actual cross-published PE/deps/config and malformed packages, but cannot establish
Windows execution, junction or symlink acceptance. CI prints native smoke and
elapsed-time summaries; the existing 20-minute Windows gate limit is unchanged
pending real timing evidence. Do not skip safety tests to meet the limit.

## PR6/PR7/PR8 handoff and remaining work

The verified result includes an exact file inventory including the Host manifest,
but explicitly reports `installation_permitted=false`. It has **no PR6
release-manifest.json**, so PR7 installation and PR8 uninstall reject it. Copying
these binaries into an existing PR6/PR7 install directory would create unowned
files and is not an authorized installation workflow.

A future controlled product-composition stage must independently verify the Host
receipt and PR6 source receipt, produce a trusted combined artifact ledger, and
integrate that ledger with PR7 ownership/PR8 verification before installation.
PR9 does not fabricate PR6 Git-archive provenance for generated binaries or
change its schema. Full V1 assembly/installation, stop/start lease integration,
upgrade/rollback, signing and Windows release acceptance remain separate work.
Code rollback uses ordinary revert and does not delete existing releases or
restore installations. No application version bump or automatic lifecycle action
is performed by this packaging slice.
