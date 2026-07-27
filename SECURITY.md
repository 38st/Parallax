# Security policy

Parallax manages launch configuration and profile storage, but it does not
provide an operating-system security boundary. Read
[Isolation and data ownership](docs/ISOLATION_AND_DATA.md) before using profiles
for sensitive separation.

## Supported versions

Security fixes are applied to the latest published release and the default
branch. Older releases may not receive fixes.

## Reporting a vulnerability

Please do not open a public issue for a suspected vulnerability.

Use GitHub's **Security** tab and select **Report a vulnerability** to submit a
private report. If private vulnerability reporting is unavailable, open a
minimal issue asking the maintainers for a private contact channel. Do not put
exploit details, credentials, personal data, or sensitive filesystem paths in
that issue.

Include the following when it is safe to do so:

- the affected Parallax version or commit;
- the macOS and affected application versions;
- a concise description of the impact;
- reproducible steps or a proof of concept using synthetic data;
- any suggested mitigation.

Please allow the maintainers time to investigate and prepare a fix before
public disclosure.

## Sensitive data

Redact profile names, environment values, command arguments, account details,
Keychain content, home-directory paths, and application data from reports,
logs, screenshots, and test fixtures.
