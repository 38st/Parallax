# Parallax production readiness

## Executive assessment

**Source release candidate: locally verified. Public release: NO-GO pending a
clean reviewed commit and authorized signing/notarization.**

All locally actionable P1 and macOS release-candidate P2 findings discovered in
this review are implemented and covered by regression tests. The exact working
tree builds, the Swift suite passes, the packaging integration builds and
independently verifies local, ZIP, and DMG artifacts, the canonical ZIP is
byte-reproducible, isolated install/upgrade/rollback is rehearsed, and a
redacted secret scan reports no findings.

This is not authority to ship the current directory. It contains substantial
pre-existing user-owned modifications and untracked files, so release mode now
rejects it by design. A maintainer must review and commit the intended source,
then run the signed/notarized release gate with authorized credentials.

The July 28, 2026 ChatGPT failures remain attributed to the managed
application's native remote-hosted Picture-in-Picture/XPC path, not Parallax.
Parallax now owns detection, exact profile containment, conservative
crash-report attribution, bounded automatic recovery, explicit manual recovery,
and durable workaround visibility.

`ParallaxMobile/` is an explicitly excluded prototype and is not part of this
macOS release candidate.

## Architecture summary

Parallax is a macOS 14+ SwiftUI application built as a Swift Package
executable. `LibraryStore` coordinates the versioned library, transactional
profile-data operations, launch preparation, scene presentation, recent
activity, crash recovery, and workaround records. `WorkspaceApplicationLauncher`
opens managed applications through `NSWorkspace` and retains exact process
lifecycles. Stable logical and storage UUIDs bind applications and profiles to
managed directories beneath configured base roots.

Important safety boundaries:

- Parallax is a launcher/supervisor, not an operating-system security boundary.
- Profile and application storage identities are distinct from display names.
- Durable activity receipts and an interprocess lock prevent two Parallax
  processes from claiming the same profile or managed process.
- External paths remain user-owned and are not treated as mutation
  capabilities.
- Sensitive values belong in Keychain-backed environment references; suspected
  secrets in process arguments are blocked because argv is observable.
- Automatic recovery occurs only after a uniquely matching macOS crash report.
  It never treats an unconfirmed quit as a crash, and its profile-scoped retry
  circuit persists safely across Parallax restarts and concurrent processes.
- Recent Activity merges updates across Parallax processes and exports a
  strict-allowlist sanitized support bundle.
- Large interactive managed-data operations execute outside the main actor
  after immutable authorization and prepared-commit validation.
- Third-party workarounds are recorded and displayed, but Parallax does not
  mutate unstable vendor settings.

## Verification summary

Environment on July 28, 2026:

- Swift 6.3.3
- Xcode 26.6 (17F113)
- macOS SDK 26.5
- arm64 macOS test host

Final local evidence:

- `swift build`: PASS
- `swift test`: PASS, 616 tests, 0 failures
- `./script/test_build_and_run.sh`: PASS, 4/4 contract tests
- packaging integration: PASS, 5/5; app, reproducible ZIP, DMG, install/
  upgrade/rollback, signatures, provenance, and artifact collision checks
  verified
- `gitleaks 8.30.1 dir . --redact`: PASS, 0 findings
- `git diff --check`: PASS
- mobile simulator build/tests: PASS, 2 tests; informational only because the
  mobile prototype is excluded

The repository was already dirty before this work began: 39 tracked files were
modified and multiple source, UI, test, and mobile paths were untracked. Those
changes remain user-owned and were not reverted, staged, or committed.

## Readiness artifacts

- [Authoritative gap register](gap-register.md)
- [Critical journeys](critical-journeys.md)
- [Managed-app crash incident](managed-app-crash-incident.md)
- [Release gate and decision](release-gate.md)
