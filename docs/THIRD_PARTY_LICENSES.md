# Third-party licences

The shipped product has **no third-party package dependency**: the Router Host
projects reference only each other, and the Host release is framework-dependent
(the .NET runtime is installed separately and is not redistributed).

The packages below are used **only to build and run the test suites**. They are
restored from NuGet at test time and are not redistributed in any release
artifact. Each licence was checked against the package's own NuGet metadata
(`.nuspec`) in the local package cache; one needed the upstream source repository.

| Package | Version | Licence | Evidence |
|---|---|---|---|
| xunit | 2.9.3 | Apache-2.0 | nuspec `license` expression |
| xunit.assert | 2.9.3 | Apache-2.0 | nuspec `license` expression |
| xunit.core | 2.9.3 | Apache-2.0 | nuspec `license` expression |
| xunit.extensibility.core | 2.9.3 | Apache-2.0 | nuspec `license` expression |
| xunit.extensibility.execution | 2.9.3 | Apache-2.0 | nuspec `license` expression |
| xunit.analyzers | 1.18.0 | Apache-2.0 | nuspec `license` expression |
| xunit.runner.visualstudio | 4.0.0 | Apache-2.0 | nuspec `license` expression |
| xunit.abstractions | 2.0.3 | Apache-2.0 | see below |
| Microsoft.NET.Test.Sdk | 18.9.0 | MIT | nuspec `license` expression |
| Microsoft.TestPlatform.ObjectModel | 18.9.0 | MIT | nuspec `license` expression |
| Microsoft.TestPlatform.TestHost | 18.9.0 | MIT | nuspec `license` expression |
| Microsoft.CodeCoverage | 18.9.0 | MIT | nuspec `license` expression |

## xunit.abstractions 2.0.3

This older package carries no SPDX licence expression and embeds no licence
file. Its metadata declares the licence only by URL.

- NuGet package page: <https://www.nuget.org/packages/xunit.abstractions/2.0.3>.
  The owner is `xunit`, the project site is <https://github.com/xunit/xunit>,
  and the "License Info" link points to
  `https://raw.githubusercontent.com/xunit/xunit/master/license.txt`.
- The package's source repository licence notice is at
  <https://github.com/xunit/abstractions.xunit/blob/main/license.txt>. It
  states that the source is "Licensed under the Apache License, Version 2.0"
  and reads "Copyright (c) .NET Foundation and Contributors".

Status: **Apache-2.0, confirmed from the upstream source repository's licence
notice.** The package metadata itself names the licence only by URL. It is a
test-only dependency and is not redistributed. No dependency was replaced.

This project's own licence is the unmodified [Apache License 2.0](../LICENSE).
