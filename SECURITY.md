# Security Policy

## Supported Versions

Strip has not reached a stable release. Security fixes apply to the latest `main` branch only. There
are no supported binary release lines.

## Reporting a Vulnerability

Do not open a public issue. Use GitHub's private vulnerability report form:
<https://github.com/shidil/strip/security/advisories/new>.

Before making the repository public, the repository owner must enable GitHub private vulnerability
reporting and verify that this link works from a non-maintainer account. If the form is unavailable,
do not disclose the vulnerability publicly; contact the maintainer through a private contact method
listed on their GitHub profile.

Include the affected commit, macOS version, permission state, reproduction steps, impact, and
redacted evidence. The maintainer responds on a best-effort basis; this experimental project has no
fixed response or remediation SLA.

Strip intentionally receives Accessibility permission, can control other applications' windows,
and can capture window thumbnails when Screen Recording is granted. See [PRIVACY.md](PRIVACY.md).
