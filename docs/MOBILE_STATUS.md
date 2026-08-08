# Mobile status

## Decision

Parallax mobile production is formally deferred. The supported product and
release candidate remain the macOS application. Mobile is not part of the
macOS build, test, packaging, signing, notarization, or publication gates.

The current `master` tree contains no `ParallaxMobile/` directory. Mobile
prototype source is preserved separately on the local branch
`wip/parallax-mobile-prototype-20260729` at the exact checkpoint commit:

```text
feb7daaf177e0dfc9ac95767f6d24c74c4ee904b
MOB-001: checkpoint mobile prototype
```

Keep that branch and commit intact until the checkpoint is also preserved on a
verified remote ref. The checkpoint is an archival prototype, not a release,
supported product, or source of claims about current `master` behavior.

## Prototype behavior

The checkpoint is an iPhone-only iOS 17+ SwiftUI prototype. It demonstrates:

- persistent, named `WKWebsiteDataStore` instances associated with website
  spaces;
- Instagram, ChatGPT, and custom website presets;
- a locally persisted space library;
- back, forward, reload, and start-page navigation;
- per-space website-data reset and space deletion; and
- two model-level tests covering starter-space identifier uniqueness and JSON
  round-tripping.

### Compile evidence

On August 8, 2026, the exact checkpoint commit was exported with `git archive`
to `/tmp/parallax-mobile-audit.yZJSIP/ParallaxMobile`; the branch was not
checked out or modified. The audit host reported Xcode 26.6, build `17F113`, and
iPhone Simulator SDK 26.5, build `23F81a`. Both commands used the shared
`ParallaxMobile` scheme, the generic iOS Simulator destination, an isolated
DerivedData directory, and disabled code signing:

```bash
xcodebuild -project ParallaxMobile.xcodeproj -scheme ParallaxMobile \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/parallax-mobile-audit.yZJSIP/DerivedData \
  CODE_SIGNING_ALLOWED=NO build

xcodebuild -project ParallaxMobile.xcodeproj -scheme ParallaxMobile \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/parallax-mobile-audit.yZJSIP/DerivedData \
  CODE_SIGNING_ALLOWED=NO build-for-testing | tail -40
```

The first shell command exited with status 0 and emitted `BUILD SUCCEEDED`.
The second pipeline exited with status 0 and its retained output emitted
`TEST BUILD SUCCEEDED`, proving that the app and two-test bundle compiled. The
pipeline did not preserve `xcodebuild`'s status independently of `tail`, so the
success banner, rather than the pipeline status alone, is the evidence for the
test build.

CoreSimulatorService was unavailable in the sandbox. No simulator booted, no
test case executed, no physical device was used, and no `.xcresult` runtime
result was produced. These results therefore prove compilation only; they do
not constitute fresh simulator testing, signing, installation, physical-device
qualification, or production verification.

## Why mobile stays off `master`

The checkpoint proves a UI and WebKit profile-browsing concept, but it does not
establish a production product contract or production safety. In particular,
it does not yet provide:

- a versioned metadata repository, migrations, corruption quarantine, atomic
  publication, backup, restore, or restart-safe recovery;
- validation that persisted space and data-store identifiers remain unique;
- transactional reset and deletion with residual-data inventory and retry;
- an explicit origin, redirect, popup, OAuth, download, and external-scheme
  policy;
- complete loading, offline, TLS-error, permission, and WebContent-crash
  recovery states;
- a local HTTPS isolation harness proving separation and reset across cookies,
  local storage, IndexedDB, caches, and service workers;
- onboarding and full library management, accessibility, localization, or
  stable UI automation;
- a privacy manifest, threat model, retention policy, App Privacy disclosures,
  or physical-device evidence; or
- mobile CI, app assets, signing/provisioning, TestFlight, upgrade, rollback,
  and App Store release procedures.

Keeping the checkpoint separate prevents prototype behavior and historical
test results from being mistaken for supported macOS behavior or release
evidence. It also avoids coupling macOS release progress to an undecided mobile
product.

## Independent release train

If mobile resumes, it must use an independent release train. Mobile and macOS
must have separate:

- version and build numbers;
- CI workflows and pinned Xcode/toolchain requirements;
- signing identities, provisioning profiles, credentials, and protected
  publication approvals;
- artifacts, provenance, test evidence, and retention;
- installation, upgrade, recovery, and rollback procedures; and
- release decisions and public support commitments.

An iOS or TestFlight result must not satisfy a macOS gate, and a macOS result
must not satisfy a mobile gate.

## Re-entry decisions

Before moving mobile source onto `master` or distributing it to testers, record
an approved decision for each of the following:

1. Whether mobile is a standalone website-space browser or a companion to the
   macOS product.
2. Whether it supports arbitrary websites, an approved service catalog, or
   both.
3. Whether named services such as Instagram and ChatGPT are supported and
   compatibility-tested or are examples only.
4. The distribution channel, bundle ownership, developer team, minimum iOS
   version, and supported device matrix.
5. The exact isolation promise, including its limits around external apps,
   passkeys, autofill, operating-system services, backups, and synchronization.
6. Supported camera, microphone, upload, download, notification, location,
   dialog, OAuth, payment, and external-link behavior.
7. Whether metadata is local-only or participates in sync, backup, import, or
   export.
8. Privacy, retention, telemetry, support, incident-response, trademark, and
   App Store review commitments.
9. Required locales, accessibility bar, release ownership, and rollback
   policy.

If these decisions do not produce an approved mobile product contract, the
formal deferral remains in force.

## Re-entry verification gates

Production mobile status requires evidence bound to an exact source commit for
all of the following:

- deterministic project generation and warning-clean debug and release builds;
- unit coverage for metadata schemas, migrations, invariants, navigation
  policy, transactions, and redaction;
- integration coverage for named-store isolation, reset, delete, relaunch,
  upgrade, corruption, future schemas, redirects, popups, OAuth, and external
  schemes;
- failure-injection coverage proving that interrupted metadata and WebKit data
  operations recover without silent loss or retained data becoming
  unreachable;
- critical-journey UI automation and manual VoiceOver, Dynamic Type,
  localization, appearance, contrast, and reduced-motion verification;
- current and minimum-iOS physical-device testing for real sign-in,
  permissions, uploads, downloads, passkeys, autofill, IPv6-only networking,
  backgrounding, termination, memory pressure, and network transitions;
- an approved threat model, valid privacy manifest and privacy report,
  accurate App Privacy disclosures, redacted diagnostics, and data-retention
  policy;
- independent mobile CI, archive validation, app assets, support and privacy
  URLs, signing and provisioning, and authorized TestFlight qualification;
- clean installation, representative-data upgrade with WebKit continuity,
  recovery, and data-compatible rollback; and
- independent security, privacy, accessibility, and release review with no
  unresolved release-blocking findings.

Until every applicable gate passes, mobile remains a preserved prototype and
must not be described as production-ready or included in a public Parallax
release.
