# Security Policy

## Reporting a vulnerability

Please **do not** open a public issue for a security problem.

Report it privately through GitHub's private vulnerability reporting for this
repository (**Security → Report a vulnerability**). Include:

- the affected component (installer scripts, Local Router, V4 console, release
  packaging, installation ownership or uninstall);
- the version or commit you tested;
- reproduction steps, using fake or redacted values only.

**Never include a real API key, token, password, Codex `auth.json`, `config.toml`
or any other credential or personal data in a report.** If a real credential was
exposed, revoke it at its provider first.

## Scope

In scope: credential handling and redaction, the loopback-only Local Router and
its control plane, Provider request routing, release package provenance,
installation ownership, uninstall safety, and CI configuration.

Out of scope: vulnerabilities in third-party Providers, Codex itself, the .NET
runtime or GitHub, which should be reported to their maintainers.

## Expectations

This is a community-maintained project provided under the Apache License 2.0,
without warranty and without a guaranteed response time. Reports are reviewed on
a best-effort basis, and fixes go through the same Development Gate as every
other change.
