# Parallax production readiness

## Executive assessment

**The current source and unsigned/ad-hoc artifact lanes are locally verified.**

Public binary distribution remains gated on an approved version, Developer ID
and notarization credentials, clean-account validation of the exact signed
artifacts, and explicit publication approval. Those are external release
inputs, not unresolved source defects.

Last local verification: September 10, 2026, at source commit `3fc2988`.

## Current release evidence

- warning-clean release build: PASS;
- complete warning-clean test suite: PASS — 1,264 tests, 0 failures, one
  documented foreground-activation capability skip;
- fresh isolated coverage suite: PASS — 46,413 / 71,430 product lines
  (64.9769%) against a 53.1252% floor;
- localization: PASS — 1,025 source keys with 1,035 entries in each of
  English and Spanish, zero dynamic keys, unknown interpolations, or accepted
  debt;
- gitleaks 8.30.1: PASS — zero findings;
- Address and Thread Sanitizer lanes: PASS — 1,264 tests each, zero
  diagnostics;
- evidence-hygiene, coverage, warning, localization, and packaging contract
  suites: PASS;
- native packaging integration: PASS — local app, reproducible ZIP, DMG,
  provenance, collision handling, and isolated install/upgrade/rollback;
- shared workspace sidebar and configured Claude profile storage: covered by
  the build, full suite, and focused integration tests.

There is no hosted CI. Every gate above is a local script run from the
repository root; the release gate lists the exact commands. Signed/notarized
distribution is a manual credentialed procedure.

## Safety boundaries

- Parallax is a launcher and supervisor, not an operating-system security
  boundary.
- Claude spaces receive distinct managed `--user-data-dir` and
  `CLAUDE_CONFIG_DIR` locations. Claude can still share its login through
  macOS, and Parallax does not copy or merge chats between spaces.
- Managed Claude configuration directories are revalidated and forced to
  owner-only `0700` immediately before launch.
- External paths remain user-owned and are never treated as managed mutation
  capabilities.
- Provider usage is shown only when the installed provider tool returns a
  parseable live value. Missing data stays unavailable rather than inferred.
- Sensitive values belong in Keychain-backed environment references; suspected
  secrets in process arguments are blocked.

## Readiness artifacts

- [Release gate and decision](release-gate.md)
- [Authoritative gap register](gap-register.md)
- [Critical journeys](critical-journeys.md)
- [Managed-app crash incident](managed-app-crash-incident.md)
- [Build and release](../BUILD_AND_RELEASE.md)
