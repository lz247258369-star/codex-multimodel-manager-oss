# LR-15 PR7 — Install Ownership Manifest v1

This slice adds a minimal, opt-in installation primitive for PR6 release
packages and a read-only removal planner. It does not run the legacy Manager
setup, install a Skill, start Router Host, change Direct Mode, or implement an
uninstaller, upgrade, rollback drill or Host release packaging.

## Installation boundary

Import `installer/scripts/router-install-ownership.psm1` in PowerShell 7.
`Install-RouterOwnedPackage` requires explicit `PackageRoot`, `InstallRoot` and
`ExpectedPackageSha256`. The expected digest must come from the operator's
trusted PR6 release evidence, not an untrusted package's own assertion.
The destination must not exist, even as an empty directory; its parent must
already exist. This prevents adoption or overwrite of pre-existing user files.
Codex `.codex` directories and linked ancestors are refused.

The primitive verifies the package with the existing PR6 `-Verify` entrypoint,
checks product identity and the expected digest, rejects unsafe Windows paths
and case-colliding names on every platform, then copies into a new sibling
staging directory. Every copied byte is checked against the verified ledger.
The ledger is written and validated before a directory rename publishes the
installation. A concurrent existing destination makes publication fail without
overwrite. Failed staging is retained for inspection; it is never recursively
deleted by the installer.

The installer owns only the newly copied, verified package payload,
`release-manifest.json` and its new `router-install-ownership.json`. This is an
artifact installation directory, not an assertion that Router Host is packaged
or ready. No files outside that directory are claimed.

## Versioned receipt

The ownership manifest uses `schema_version: 1`, product
`codex-multimodel-manager`, a fresh UUID `installation_id`, canonical absolute
`install_root`, the PR6 package `version`, `source_commit` and `package_sha256`,
and exact relative `files` entries containing `path`, `size` and `sha256`.
`managed_config` is an empty array in v1. Unknown schemas, unknown fields,
incomplete/duplicate entries and wrong identity types are rejected.

The package/product version is inherited from PR6; this infrastructure slice
does not bump the product version in `manifest.json`. Keep the returned
installation receipt and trusted release package outside the installed tree
for later verification. A copied or edited ownership manifest alone is never
sufficient deletion authority. PR6 hashes prove integrity, not signing or
publisher authenticity; this slice does not change that trust contract.

## Exact removal boundary (planning only)

`Get-RouterOwnedRemovalPlan` requires the trusted package, expected package
digest, expected installation UUID and explicit installation root. It checks
the strict manifest against that package and rehashes every owned file. Missing,
modified or unexpected ownership entries block the entire plan. Symlinks,
Windows junctions and other reparse points anywhere in the traversed tree or
its ancestors block planning without traversing them.

The result contains exact `delete_files`, explicit `preserve_files`, empty
`delete_directories`, and `execution_permitted: false`. It includes the ownership
manifest itself but never authorizes recursive directory deletion. Extra normal
files are preserved. Codex `config.toml`, `auth.json`, Router runtime config,
logs, state, backups, handoffs, reports and secret/database files cannot be
claimed by payload paths. Existing CLI/Desktop provider ownership registries
and Secret Bridge receipts retain their own semantics and are not adopted.

Example for an **isolated test directory**, using an externally verified digest:

```powershell
Import-Module ./installer/scripts/router-install-ownership.psm1
$receipt = Install-RouterOwnedPackage -PackageRoot $verifiedPackage `
    -InstallRoot $newIsolatedDirectory -ExpectedPackageSha256 $trustedDigest
$plan = Get-RouterOwnedRemovalPlan -PackageRoot $verifiedPackage `
    -InstallRoot $receipt.install_root -ExpectedPackageSha256 $trustedDigest `
    -ExpectedInstallationId $receipt.installation_id
# Inspect the plan. PR7 supplies no deletion executor.
```

This is an offline, single-operator boundary, not protection against an attacker
who can concurrently rewrite the package, installation and receipt. A future
uninstaller must revalidate ownership immediately before each operation and
address process/lifecycle and concurrent filesystem mutation explicitly. It
must not treat a saved plan as enduring deletion authority.

## Validation and rollback

Run `pwsh -NoProfile -File tests/validate-router-install-ownership.ps1`.
The existing Development Gate invokes it through `tests/validate-repo.ps1`,
without changing the CI workflow. Tests create a synthetic Git repository,
PR6 artifact and temporary install roots; no real user config or API key is
used. They cover publication, refusals, corrupt/forged ledgers, tampering,
identity, preserved user/runtime files and linked-directory boundaries.
Windows uses actual junctions without requiring symlink privileges; Linux
uses actual symbolic links. Windows CI remains required evidence for Windows.

Code rollback is a normal revert of the PR7 commits. Installed artifacts are
not automatically removed on code rollback. No real installation was created
by this development task. Failed staging and isolated test cleanup must not be
confused with a supported user uninstall or upgrade rollback drill.
