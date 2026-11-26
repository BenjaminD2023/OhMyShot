# Security Policy

## Supported Versions

Security fixes are delivered through signed releases of OhMyShot. Only the latest release line receives security updates:

| Version | Supported |
| --- | --- |
| 0.5.x (latest release) | Yes |
| < 0.5.0 | No — please update via Sparkle or [GitHub Releases](https://github.com/MMFoundation/OhMyShot/releases/latest) |

## Reporting a Vulnerability

Please **do not** report security vulnerabilities through public GitHub Issues or pull requests.

Instead, report them privately through either of the following channels:

1. **GitHub Security Advisories (preferred):** Open a private vulnerability report at [MMFoundation/OhMyShot Security Advisories](https://github.com/MMFoundation/OhMyShot/security/advisories/new).
2. **Email:** Send details to [support@ohmyshot.org](mailto:support@ohmyshot.org).

Include as much of the following as you can so we can reproduce and address the issue quickly:

- A clear description of the vulnerability and its potential impact.
- OhMyShot version/build number and macOS version.
- Step-by-step reproduction instructions or a minimal proof of concept.

## Response & Disclosure

- We aim to acknowledge new reports within **3 business days** and share an initial assessment once we have reproduced the issue.
- We will coordinate a fix and release timeline with you before any public disclosure, and credit you in the release notes if you wish.

## Release Integrity & Scope

- Official release builds are signed with an Apple Developer ID certificate, notarized by Apple, and delivered via EdDSA-signed Sparkle appcasts and archives.
- Reports concerning code signing, Sparkle update verification, redaction/flattening safety, URL scheme approval boundaries (`ohmyshot://`), or local file/clipboard isolation are all in scope.
- For general privacy questions or data requests (not security vulnerabilities), see the [Privacy Notice](https://www.ohmyshot.org/privacy/).
