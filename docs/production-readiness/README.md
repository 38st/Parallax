# Parallax production readiness

## Executive assessment

**The current source and unsigned/ad-hoc artifact lanes are locally verified.**

Public binary distribution remains gated on an approved version, Developer ID
and notarization credentials, clean-account validation of the exact signed
artifacts, and explicit publication approval. Those are external release
inputs, not unresolved source defects.

Last local verification: September 27, 2026, at source commit `a85f70e`.

## Current release evidence

- warning-clean release build: PASS;
- complete warning-clean test suite: 1,899 tests, 0 failures, 1 documented capability skip;
- fresh isolated coverage suite: 55,261 / 79,738 product lines (69.3032%) against a 51,137 / 75,458 (67.7688%, measured at 84b67f7) floor;
- localization: 1,203 source keys; 1,206 English and 1,206 Spanish entries, zero debt;
- pinned gitleaks secret scan: PASS;
- Address and Thread Sanitizer lanes: PASS;
- evidence-hygiene, coverage, warning, localization, and packaging contract
  suites: PASS;
- native packaging integration (local app, reproducible ZIP, DMG, provenance,
  collision handling, and isolated install/upgrade/rollback): PASS;
- shared workspace sidebar and configured Claude profile storage: covered by
  the build, full suite, and focused integration tests.

There is no hosted CI. Every gate above is a local script run from the
repository root; the release gate lists the exact commands. Signed/notarized
distribution is a manual credentialed procedure.

## Safety boundaries

- Parallax is a launcher and supervisor, not an operating-system security
  boundary.
- Claude spaces receive distinct managed `--user-data-dir` and
  `CLAUDE_CONFIG_DIR` locations. A version-gated local Code conversation-copy
  preview preserves each space's credentials; see
  [conversation copying](../CLAUDE_CONVERSATION_COPY.md). This does not merge
  accounts or create an OS security boundary.
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
