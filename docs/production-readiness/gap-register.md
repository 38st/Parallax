# Production-readiness gap register

This is the authoritative findings ledger, last refreshed September 28, 2026 at
`8c88e71` (clean source tree). “Verified” means the locally actionable change
is implemented and tested; it does not imply that external signing or publication was
authorized.

Citations name files, types, functions, and tests instead of line numbers,
because source files are split as they grow. PRX-021 to PRX-038 come from the
bug audit of `e6123cf` (September 26, 2026) and the review of its fixes.
“Audit finding N” refers to that audit's numbered findings; the audit report
itself is not in the repository, so each entry restates what was found.

Current evidence: all 14 local gates passed via
`./script/run_quality_gates.sh --full` at `8c88e71`: 2,121 tests, 0 failures,
2 skipped; 1,303 source keys from 1,499 literals, 1,310 English and 1,310 Spanish
entries, zero localization debt or new issues; product line coverage
58,587 / 84,463 (69.36%) against 51,137 / 75,458 (67.77%). Address Sanitizer,
Thread Sanitizer, and native packaging integration (12/12: reproducible ZIP,
DMG, install/upgrade/rollback, provenance, collision verification) passed.
The skips were
`NSWorkspaceApplicationLauncherIntegrationTests.testWorkspaceControllerActivatesOnlyTheExactTrackedInstance`
(documented capability skip) and
`ReadmeScreenshotRenderingTests.testRenderReadmeScreenshots` (opt-in README
screenshot renderer). Artifact evidence is ad-hoc only; Developer ID signing
and notarization were not done. Earlier per-entry results remain historical;
see the [release gate](release-gate.md) for current commands and boundaries.

## PRX-001 — Managed crashes lacked attribution and controlled recovery

- **Category:** Reliability / Observability
- **Status:** Verified
- **Severity:** P1
- **Likelihood:** High; observed incident
- **Confidence:** High
- **Evidence:** Previously every termination was presented as closed. The
  lifecycle disposition and observed-PID fallback are recorded on
  `LaunchHistoryEntry` (`Stores/LaunchHistoryModels.swift`) and
  `TrackedApplicationLaunch` (`Services/TrackedLaunchSession.swift`); strict
  crash-report matching is `ApplicationCrashReportIndex.reports(…)`
  (`Services/ApplicationCrashReportLocator.swift`); crash confirmation and
  automatic recovery are `scheduleCrashConfirmation(…)`
  (`Stores/LibraryStore+LaunchLifecycleEvents.swift`) with
  `ManagedAppRecoveryPolicy` and `ManagedAppRecoveryLedger`
  (`Services/ManagedAppRecoveryPolicy.swift`).
- **Affected components:** launcher, history, crash-report locator, recent
  activity, settings, recovery policy.
- **Reproduction / scenario:** Simulate an unexpected managed-process exit,
  then provide zero, one, or multiple PID-compatible crash reports.
- **Impact:** A vanished app previously had no safe automatic or explicit
  recovery flow and could enter an uncontrolled restart loop if naive retry was
  added.
- **Root cause:** The launch abstraction tracked opening, not supervised
  termination evidence or recovery decisions.
- **Proposed fix:** Distinguish requested termination, preserve the observed PID,
  link only unique identity/time-compatible reports, expose manual reopen, and
  gate automatic recovery behind confirmed crash evidence with backoff and a
  circuit breaker.
- **Required tests:** expected/unexpected lifecycle, immediate-exit matching,
  bundle rejection, per-profile backoff, rolling-window reset, circuit opening,
  and manual reopen.
- **Dependencies:** macOS controls when `.ips` reports appear; production uses a
  bounded two-second discovery grace period.
- **Estimated complexity:** Large
- **Resolution / verification:** Implemented `ManagedAppRecoveryPolicy`
  (2-second then 8-second retry; two attempts per ten-minute profile window),
  the “Automatically reopen after a confirmed crash” setting, strict report
  matching, and exact Parallax-quit disposition. Recent Activity labels an exit
  “Crashed” when a matching crash report is linked and “Closed” otherwise
  (`LaunchHistoryEntryPresentation` in `Models/RecentActivityModel.swift`).
  Tests: `ApplicationCrashReportLocatorTests.testMatchesReportByProcessStartIdentityAndBundle`,
  `ManagedAppRecoveryPolicyTests.testConfirmedCrashesBackOffAndOpenCircuitWithinWindow`,
  `LaunchHistoryStoreTests.testPresentationUsesPlainLanguageAndDuration`.
  Full suite at `a85f70e`: 1,899 tests, 0 failures, 1 documented capability skip.

## PRX-002 — Durable activity protection could silently degrade

- **Category:** Reliability / Data integrity / Observability
- **Status:** Verified
- **Severity:** P1
- **Likelihood:** Low to medium
- **Confidence:** High
- **Evidence:** Bootstrap previously used unannotated `try?` fallbacks.
  `ParallaxSharedServices.init` (`App/ParallaxAppComposition.swift`) now
  preserves the initialization error, and `LibraryStore.init` enters
  `.recoveryRequired` with it.
- **Affected components:** shared services, every scene store, launch and
  destructive-operation gates.
- **Reproduction / scenario:** Make Application Support unavailable during
  startup.
- **Impact:** Restart could otherwise lose activity evidence and permit unsafe
  concurrent profile mutation.
- **Root cause:** A safety-critical persistence error was converted to a normal
  in-memory service.
- **Proposed fix:** Retain the causal error, inject it into every store, surface
  it, and block safety-sensitive operations.
- **Required tests:** injected bootstrap failure reaches a store and produces
  recovery-required state.
- **Dependencies:** None
- **Estimated complexity:** Medium
- **Resolution / verification:** `testSharedActivityBootstrapFailureFailsClosed`
  passes. Full suite at `a85f70e`: 1,899 tests, 0 failures, 1 documented capability skip.

## PRX-003 — Incident workaround state was not durable or visible

- **Category:** Implementation gap / UX / Operations
- **Status:** Verified
- **Severity:** P1
- **Likelihood:** High while incident containment is needed
- **Confidence:** High
- **Evidence:** `ManagedAppWorkaroundStore.swift` now stores versioned records
  by stable application/profile storage identity; `ApplicationHeaderView.swift`
  exposes the ChatGPT incident record without editing vendor state.
- **Affected components:** app settings, persistence, incident operations.
- **Reproduction / scenario:** Record the PiP workaround for one profile,
  restart Parallax, and inspect another profile.
- **Impact:** Operators previously could not tell which isolated profile had
  containment or retain that fact across restart.
- **Root cause:** No generic workaround model existed.
- **Proposed fix:** Add generic versioned records with state, definition
  version, configuration reference, timestamp, and bounded note. Never mutate
  unstable third-party internals.
- **Required tests:** round-trip, unknown future ID/version, cross-profile
  isolation, removal, corrupt quarantine, and restrictive permissions.
- **Dependencies:** The profile owner must apply and verify the external vendor
  setting before recording it.
- **Estimated complexity:** Medium
- **Resolution / verification:** Store, corruption quarantine, `0700`/`0600`
  hardening, UI, and two regression tests are implemented. Full suite at
  `a85f70e`: 1,899 tests, 0 failures, 1 documented capability skip.

## PRX-004 — Release artifact and signed distribution gate

- **Category:** Build / Release
- **Status:** Blocked by an explicit external dependency or decision
- **Severity:** P1 for public distribution; not a source-RC defect
- **Likelihood:** Certain until release authorization
- **Confidence:** High
- **Evidence:** Packaging integration built and verified a local app, ZIP, DMG,
  signatures, provenance, collision handling, and isolated
  install/upgrade/rollback. Release mode rejects dirty source and missing
  credentials before artifact mutation. Verification is now fail-closed from
  the outside in: bounded archive input, byte-parsed canonical ZIP container,
  ZIP entry name/kind and payload-integrity checks, AppleDouble exclusion for
  unsigned archives, DMG image-structure preflight, and an exactly
  closed application inventory with canonical bundle permissions.
- **Affected components:** `script/build_and_run.sh`, signing, notarization,
  distribution.
- **Reproduction / scenario:** Run `release` from a dirty tree or without
  Developer ID/notary credentials.
- **Impact:** Publishing from an unreviewed tree or without platform trust.
- **Root cause:** Required human review/commit and external credentials are
  intentionally unavailable to this task.
- **Proposed fix:** Review and commit the intended changes, run the clean-tree
  signed release, notarize, staple, verify, install on a clean account, and
  retain provenance.
- **Required tests:** clean-tree release, `codesign`, `spctl`, notarization,
  stapling, ZIP/DMG verification, upgrade, and rollback.
- **Dependencies:** Maintainer approval, Developer ID credentials, Apple notary
  service, and explicit release authority.
- **Estimated complexity:** Medium operational work
- **Resolution / verification:** Locally actionable unsigned/ad-hoc packaging
  is verified by the native packaging integration run; result at
  `a85f70e`: PASS. Public release remains NO-GO.

## PRX-005 — Sensitive persistence files could retain permissive modes

- **Category:** Security / Privacy / Data integrity
- **Status:** Verified
- **Severity:** P2
- **Likelihood:** Low
- **Confidence:** High
- **Evidence:** Existing `library.json` was observed as `0644`. Hardening now
  covers final library replacement in `LibraryPersistence.swift`, launch
  history/quarantine in `LaunchHistoryStore.swift`, removal journals in
  `ApplicationRemovalTransactionCoordinator.swift`, and workaround state.
- **Affected components:** application-support metadata and transaction
  journals.
- **Reproduction / scenario:** Pre-create directories or files with `0755` /
  `0644`, then initialize or save.
- **Impact:** Local accounts could read profile names, paths, PIDs, or operation
  metadata when parent protection is weakened.
- **Root cause:** Permissions were requested at creation but not consistently
  reasserted after replacement/quarantine.
- **Proposed fix:** Enforce `0700` directories and `0600` files after every
  publication path.
- **Required tests:** existing permissive path, normal write, quarantine, and
  journal recovery modes.
- **Dependencies:** None
- **Estimated complexity:** Small
- **Resolution / verification:** Implemented; persistence and transaction suites
  pass. Full suite at `a85f70e`: 1,899 tests, 0 failures, 1 documented capability skip.

## PRX-006 — Secrets in launch arguments escaped the environment model

- **Category:** Security / Privacy
- **Status:** Verified
- **Severity:** P1
- **Likelihood:** Medium
- **Confidence:** High
- **Evidence:** Argument text was persisted, previewed, exported, and passed via
  argv. `SensitiveLaunchArgumentPolicy`
  (`Services/SensitiveLaunchArgumentPolicy.swift`) detects secret-shaped
  options, credential URLs, and Keychain references; compiler and export paths
  consume it. Credential URLs inside option values and bare names such as
  `API_KEY` were missed until `57f11c6` (PRX-025).
- **Affected components:** editor preview, imported review, compiler, portable
  exports, child argv.
- **Reproduction / scenario:** Configure `--api-key secret`, `--token=secret`,
  or a credential-bearing URL.
- **Impact:** Secrets could be visible to process inspection, UI, and exported
  metadata.
- **Root cause:** Secret classification covered environment values but not argv.
- **Proposed fix:** Redact all presentation/export paths and make suspected argv
  secrets a non-overridable launch diagnostic; direct users to Keychain-backed
  environment references.
- **Required tests:** split/equal options, URLs, false positives, preview,
  imported review, export policies, and compiler refusal.
- **Dependencies:** None
- **Estimated complexity:** Medium
- **Resolution / verification:** Compiler, presentation, import, and portable
  configuration regression tests pass. Full suite at `a85f70e`:
  1,899 tests, 0 failures, 1 documented capability skip.

## PRX-007 — Release mode accepted a dirty source tree

- **Category:** Build / Release / Supply-chain integrity
- **Status:** Verified
- **Severity:** P1
- **Likelihood:** Medium
- **Confidence:** High
- **Evidence:** `require_clean_release_tree`
  (`script/lib/build_and_run/input_and_tools.sh`, using
  `script/check_git_state.py`) requires a valid HEAD, an empty porcelain status,
  and no skip-worktree or assume-unchanged entries, before credential
  preflight and again before signing; release compiles a `git archive`
  snapshot (PRX-033). Archive mode remains usable for candidate testing.
- **Affected components:** release automation.
- **Reproduction / scenario:** Modify or add a source file and invoke release.
- **Impact:** Artifacts could not be tied to a reviewed commit.
- **Root cause:** Release validated credentials and artifacts but not source
  cleanliness.
- **Proposed fix:** Fail before staging or credential use when tracked or
  untracked content differs from HEAD.
- **Required tests:** dirty tracked file, untracked file, and failure ordering.
- **Dependencies:** None
- **Estimated complexity:** Small
- **Resolution / verification:** The packaging contract suite
  (`./script/test_build_and_run.sh`) covers dirty-tree rejection and its
  failure ordering before staging, including
  `GateAuditRegressionTests.test_release_detects_index_visibility_flags` and
  `GateAuditRegressionTests.test_release_ignores_inputs_excluded_from_snapshot`.
  Result at `a85f70e`: PASS.

## PRX-008 — Same profile could be launched by two Parallax processes

- **Category:** Reliability / Data integrity / Isolation
- **Status:** Verified
- **Severity:** P1
- **Likelihood:** Medium
- **Confidence:** High
- **Evidence:** Process-local lease checks raced. `DurableLaunchActivityStore`
  now serializes create/record/complete/cleanup with a pinned, no-follow
  interprocess `flock` and scans durable artifacts before publication.
- **Affected components:** durable activity receipts and launch gate.
- **Reproduction / scenario:** Two registries concurrently request the same
  stable profile storage identity.
- **Impact:** Two writers could corrupt or cross-contaminate isolated profile
  data.
- **Root cause:** Durable UUID receipts were atomic individually but there was no
  cross-process check-and-create critical section.
- **Proposed fix:** Interprocess lock plus fail-closed receipt validation.
- **Required tests:** separate registries, concurrent same profile, explicit
  expert override, corrupt receipt, and root/ancestor swap.
- **Dependencies:** None
- **Estimated complexity:** Large
- **Resolution / verification:** Separate-registry atomic rejection and existing
  filesystem-adversary tests pass. Full suite at `a85f70e`:
  1,899 tests, 0 failures, 1 documented capability skip.

## PRX-009 — Successful app open could be reported as failed while still running

- **Category:** Reliability / UX
- **Status:** Verified
- **Severity:** P1
- **Likelihood:** Low to medium
- **Confidence:** High
- **Evidence:** A process-identity registration error previously canceled
  observation and released the lease after `NSWorkspace` had already opened the
  app. `TrackedApplicationLaunch.didEnterDegradedTracking(…)`
  (`Services/TrackedLaunchSession.swift`) now publishes `.runningDegraded`.
- **Affected components:** launcher lifecycle, activity gate, history, UI.
- **Reproduction / scenario:** Make durable process registration fail after a
  successful workspace open.
- **Impact:** Destructive actions could be enabled against a still-running
  process and the user saw a false open failure.
- **Root cause:** Post-open tracking failure reused the pre-open terminal failure
  path.
- **Proposed fix:** Retain observer and lease, show actionable degraded status,
  and release only on actual termination.
- **Required tests:** injected registration failure, observer retention,
  destructive gate retention, and eventual cleanup.
- **Dependencies:** None
- **Estimated complexity:** Medium
- **Resolution / verification:** Updated lifecycle regression passes. Full
  suite at `a85f70e`: 1,899 tests, 0 failures, 1 documented capability skip.

## PRX-010 — One process could be attributed to multiple profiles

- **Category:** Isolation / Data integrity
- **Status:** Verified
- **Severity:** P1
- **Likelihood:** Low
- **Confidence:** High
- **Evidence:** In-memory PID mapping could overwrite prior identity.
  `DurableLaunchActivityStore.recordProcess(requestID:process:)` now rejects a
  `ProcessStartIdentity` already owned by another request
  (`.processAlreadyTracked`).
- **Affected components:** activity registry and process attribution.
- **Reproduction / scenario:** Separate profiles try to register the same live
  PID/start tuple.
- **Impact:** Quit, status, recovery, or destructive gates could target the
  wrong profile.
- **Root cause:** Mapping uniqueness was not enforced at the durable boundary.
- **Proposed fix:** Serialize registration and reject cross-request process
  ownership.
- **Required tests:** same process/different profile and PID reuse/different
  start identity.
- **Dependencies:** None
- **Estimated complexity:** Medium
- **Resolution / verification:** `testSeparateProfilesCannotClaimTheSameRunningProcess`
  and PID-reuse tests pass. Full suite at `a85f70e`: 1,899 tests, 0 failures, 1 documented capability skip.

## PRX-011 — Identity-scoped launch ambiguity blocked the whole library

- **Category:** Reliability / Containment
- **Status:** Verified
- **Severity:** P1
- **Likelihood:** Low to medium after an interrupted open
- **Confidence:** High
- **Evidence:** Reconciliation treated any `.opening` receipt without a process
  identity as global ambiguity.
  `ProfileActivityRegistry.reconcileDurableActivity()` now separates
  target-scoped from global ambiguity (`hasGlobalDurableAmbiguity`); since
  `1da37d0` a corrupt receipt blocks only its own space
  (`DurableActivityAuditRegressionTests.testCorruptMarkerBlocksOnlyItsStorage`;
  PRX-029).
- **Affected components:** startup reconciliation and library load state.
- **Reproduction / scenario:** Interrupt one profile between request publication
  and process registration, then restart.
- **Impact:** One profile’s uncertainty made unrelated profiles unusable.
- **Root cause:** Recovery report lacked separate global and identity-scoped
  counts.
- **Proposed fix:** Fail closed for the exact identity while keeping unrelated
  identities operable.
- **Required tests:** ambiguous opening, unrelated profile activity, corrupt
  identity-less receipt.
- **Dependencies:** None
- **Estimated complexity:** Medium
- **Resolution / verification:** Scoped/global reconciliation assertions pass.
  Full suite at `a85f70e`: 1,899 tests, 0 failures, 1 documented capability skip.

## PRX-012 — Unsaved editor drafts could be lost or stale settings opened

- **Category:** UX / Data integrity
- **Status:** Verified
- **Severity:** P1
- **Likelihood:** High during normal editing
- **Confidence:** High
- **Evidence:** `ProfileEditorView` held the draft only in local `@State` while
  profile-list Open launched the persisted row. `rememberProfileEditingDraft`
  (`Stores/LibraryStore+EditingDrafts.swift`) and `ProfileEditorDraftRegistry`
  (`Stores/SceneCoordinator.swift`) retain drafts by identity, and `launch(_:)`
  (`Stores/LibraryStore+Launching.swift`) refuses a dirty space with the
  Save & Open message.
- **Affected components:** profile editor, navigation, list launch.
- **Reproduction / scenario:** Edit arguments, select another profile, return,
  or press Open in the list before Save.
- **Impact:** User intent could be silently discarded or the wrong effective
  configuration opened.
- **Root cause:** Draft ownership ended at the editor view boundary.
- **Proposed fix:** Retain draft plus staged Keychain bookkeeping in the
  scene-local store; restore on navigation; require Save & Open for a dirty
  target; block destructive/duplicate actions until commit or discard; discard
  explicitly.
- **Required tests:** navigation retention, stale list-launch block,
  Save & Open exact persisted result, failed save, and staged secret handling.
- **Dependencies:** None
- **Estimated complexity:** Medium
- **Resolution / verification:** Store/editor integration implemented;
  `testUnsavedEditingDraftIsRetainedAndBlocksStaleListLaunch` and workflow tests
  pass. Full suite at `a85f70e`: 1,899 tests, 0 failures, 1 documented capability skip.

## PRX-013 — Launch history uses last-writer-wins across Parallax processes

- **Category:** Reliability / Observability
- **Status:** Verified
- **Severity:** P2
- **Likelihood:** Low to medium
- **Confidence:** High
- **Evidence:** The original store atomically replaced one JSON document but
  did not take an interprocess merge lock.
- **Affected components:** recent activity only; safety gates use the separate
  durable activity store.
- **Reproduction / scenario:** Two Parallax processes complete launches and
  persist history concurrently.
- **Impact:** One recent-activity event can disappear; profile isolation and
  managed data remain protected.
- **Root cause:** History is a bounded presentation log, not a transactional
  multiwriter ledger.
- **Proposed fix:** Add advisory lock and reload/merge by request UUID before
  replacement.
- **Required tests:** two-store concurrent append, same-request update, corrupt
  peer, and bounded trim.
- **Dependencies:** None
- **Estimated complexity:** Medium
- **Resolution / verification:** `LaunchHistoryStore` now takes a durable
  advisory lock, reloads and merges entries by request UUID and update time,
  and applies clears to the locked disk snapshot. Two stale-store regression
  tests verify merge and clear semantics. Full suite at `a85f70e`:
  1,899 tests, 0 failures, 1 documented capability skip.

## PRX-014 — No one-click sanitized support bundle

- **Category:** Observability / Privacy / Operations
- **Status:** Verified
- **Severity:** P2
- **Likelihood:** Medium during support incidents
- **Confidence:** High
- **Evidence:** Crash reports can be opened and portable exports can redact
  configuration, but no single support-bundle workflow inventories logs,
  versions, crash references, and redaction decisions.
- **Affected components:** support and incident response.
- **Reproduction / scenario:** Ask a user to provide evidence for an intermittent
  launch failure.
- **Impact:** Slower diagnosis and higher risk of ad-hoc oversharing.
- **Root cause:** Diagnostics evolved as separate screens/export flows.
- **Proposed fix:** Add a manifest-driven, previewable bundle with strict
  allowlist, redaction report, size cap, and no secret values.
- **Required tests:** adversarial secrets, symlinks, oversized inputs, manifest,
  and deterministic redaction.
- **Dependencies:** Product decision on included diagnostics.
- **Estimated complexity:** Large
- **Resolution / verification:** Recent Activity now exports an allowlist-only
  JSON support bundle. It includes runtime/settings state, boolean persistence
  health, anonymized application/profile ordinals, sanitized activity outcomes,
  and workaround state. It excludes names, UUIDs, paths, PIDs, arguments,
  environment values, notes, Keychain references, raw crash text, and raw
  errors; output is atomically written with mode `0600`. Adversarial redaction
  and diagnostic-token tests pass. Full suite at `a85f70e`:
  1,899 tests, 0 failures, 1 documented capability skip.

## PRX-015 — Large filesystem operations can still occupy the main actor

- **Category:** Performance / UX
- **Status:** Verified for high-impact interactive operations
- **Severity:** P2
- **Likelihood:** Medium for large profiles
- **Confidence:** Medium
- **Evidence:** `LibraryStore` is `@MainActor`; several archive, migration, and
  inspection orchestration paths still perform substantial synchronous setup.
- **Affected components:** data removal/archive, migration, crash-report scan.
- **Reproduction / scenario:** Operate on a multi-gigabyte profile while
  interacting with the UI.
- **Impact:** Temporary UI stalls without data loss.
- **Root cause:** Safety-critical orchestration and presentation share one actor.
- **Proposed fix:** Move pure I/O execution behind Sendable workers while keeping
  immutable plans and commits on the main actor.
- **Required tests:** heartbeat responsiveness, cancellation, stale-plan reject,
  and race-free progress.
- **Dependencies:** Careful concurrency design.
- **Estimated complexity:** Large
- **Resolution / verification:** Profile copy/archive/delete/clear and
  application-removal transaction execution now run in detached Sendable
  workers after immutable authorization and prepared-commit creation. Storage
  relocation, launch preparation, crash scanning, and support-bundle writes
  already use background workers. The main-actor heartbeat regression pauses a
  profile transaction at its filesystem boundary and proves the UI actor
  remains available. Startup recovery still runs before the main interface is
  usable and remains fail-closed. Relocation previews hashed on the main actor
  until `6fb1250`; they are now prepared off the main thread and can be
  cancelled (`StorageRelocationAuditRegressionTests.testStorePreparesPreviewOffMainThread`).
  Full suite at `a85f70e`: 1,899 tests, 0 failures, 1 documented capability skip.

## PRX-016 — Product polish, localization, and UI automation are incomplete

- **Category:** UX / Accessibility / Testing
- **Status:** Verified for the identified release-candidate gaps
- **Severity:** P2
- **Likelihood:** Medium
- **Confidence:** High
- **Evidence:** Template deletion lacks confirmation, some async errors are easy
  to miss, Spanish coverage is partial, keyboard/focus behavior is not fully
  automated, and there is no end-to-end macOS UI suite.
- **Affected components:** settings, templates, error presentation, localization,
  keyboard/accessibility.
- **Reproduction / scenario:** Delete a template accidentally, use Spanish, or
  complete core flows keyboard-only.
- **Impact:** Recoverable friction and reduced accessibility confidence; no
  isolation or data-loss defect was reproduced.
- **Root cause:** Unit and presentation coverage carried these journeys; no
  UI automation layer was ever built.
- **Proposed fix:** Confirm destructive template actions, centralize transient
  errors, complete localization, and add XCUITest journeys.
- **Required tests:** VoiceOver labels, keyboard-only flows, focus restoration,
  localization snapshots, and destructive confirmations.
- **Dependencies:** Localization review and UI-test host stability.
- **Estimated complexity:** Medium to large
- **Resolution / verification:** Template deletion now requires an explicit
  destructive confirmation. New-space and editor actions have standard
  cancel/default/save keyboard shortcuts. Critical automation identifiers are
  centralized in `UIAutomationContract`, attached by the new-space, editor
  footer, and removal-confirmation views, and pinned by
  `UIAutomationContractTests`, so translating a label cannot change the
  identifier a later suite would target. The primary create/open/recovery/
  support labels have Spanish translations (recovery-screen titles and Recent
  Activity labels were missing until `2cd6140`; PRX-032) with a resource
  regression test.
  The critical state transitions remain covered by store and presentation
  integration tests. `Package.swift` declares no UI test target and the
  repository contains no XCUITest code, so the identifiers are currently
  exercised only by that unit test and by accessibility clients; a
  host-driven visual snapshot/XCUITest suite remains useful non-blocking
  expansion work. Full suite at `a85f70e`: 1,899 tests, 0 failures, 1 documented capability skip.

## PRX-017 — Mobile prototype is not release-complete

- **Category:** Product scope / Build
- **Status:** Deferred with rationale
- **Severity:** P2 in repository; out of scope for macOS RC
- **Likelihood:** Certain
- **Confidence:** High
- **Evidence:** [Mobile history](../MOBILE_STATUS.md) records the former
  prototype checkpoint and successful compilation of its app and two-test
  bundle; the tests were not executed. Production capabilities, security,
  migrations, and release operations were not established.
- **Affected components:** Former `ParallaxMobile/` prototype, absent from
  `master`.
- **Reproduction / scenario:** Treat the prototype as a supported shipping
  product.
- **Impact:** False platform promises.
- **Root cause:** Historical prototype evidence does not establish a supported
  mobile product.
- **Proposed fix:** Keep it excluded until a separate readiness plan defines
  product scope and gates.
- **Required tests:** Separate mobile critical-journey, security, persistence,
  device, signing, and distribution suites.
- **Dependencies:** Product scope decision.
- **Estimated complexity:** Large
- **Resolution / verification:** Explicitly excluded from this release. The
  local and remote prototype branch refs were deleted on September 28, 2026
  at the maintainer's direction, without merging the prototype into `master`.

## PRX-018 — Archives are not bit-for-bit reproducible

- **Category:** Build / Supply chain
- **Status:** Verified for the canonical ZIP artifact
- **Severity:** P2
- **Likelihood:** Certain
- **Confidence:** High
- **Evidence:** Archive provenance records the toolchain and hashes, but
  timestamps and platform tooling make repeated archives byte-different.
- **Affected components:** packaging and provenance.
- **Reproduction / scenario:** Build the same commit twice and compare archive
  hashes.
- **Impact:** Independent rebuilds require semantic verification rather than a
  byte-for-byte match.
- **Root cause:** Unnormalized timestamps and native packaging metadata.
- **Proposed fix:** Pin the toolchain and normalize archive/DMG inputs where
  compatible with signing/notarization.
- **Required tests:** two clean builds, normalized manifest comparison, and
  signature/notary compatibility.
- **Dependencies:** Apple packaging behavior.
- **Estimated complexity:** Medium
- **Resolution / verification:** Archive builds now derive or accept
  `SOURCE_DATE_EPOCH`, record it in provenance, normalize the staged app tree,
  and create the canonical ZIP with sorted entries and stripped extra metadata.
  Packaging integration builds the same source/epoch twice and requires
  byte-identical ZIP hashes. Verification now also parses the container bytes
  of every published ZIP and requires a canonical single-disk archive whose
  end record is the exact tail, whose central directory ends where that record
  begins, whose local and central headers agree byte for byte, and whose local
  entries tile the payload region contiguously, so a reproducible hash is
  backed by a canonical container rather than by the hash alone. Developer ID
  release ZIPs retain Apple-specific metadata and notarization tickets via
  `ditto`; signed ZIP/DMG bytes include authority timestamps and are
  independently ticket/content/hash verified. Packaging integration at
  `a85f70e`: PASS.

## PRX-019 — Automatic-recovery circuit state is process-memory only

- **Category:** Reliability / Operations
- **Status:** Verified
- **Severity:** P2
- **Likelihood:** Low
- **Confidence:** High
- **Evidence:** `ManagedAppRecoveryPolicy` retains rolling crash dates in memory;
  durable Recent Activity records the exits, but a Parallax restart creates a
  fresh policy.
- **Affected components:** automatic crash-loop protection.
- **Reproduction / scenario:** Produce two confirmed managed-app crashes, quit
  and reopen Parallax, then produce another confirmed crash within ten minutes.
- **Impact:** The new Parallax process can make another bounded recovery attempt
  instead of preserving the prior circuit. Each process still caps attempts, and
  exact-profile activity exclusion remains enforced.
- **Root cause:** Recovery policy was intentionally kept independent from the
  multiwriter history store for this candidate.
- **Proposed fix:** Persist a minimal profile-keyed recovery ledger with
  interprocess merge/locking, expiry, and corruption fail-safe, or derive it
  conservatively from locked history.
- **Required tests:** restart within/outside window, two Parallax processes,
  corrupt ledger, clock skew, profile isolation, and manual reset.
- **Dependencies:** PRX-013 history locking if history becomes the ledger.
- **Estimated complexity:** Medium
- **Resolution / verification:** A profile-storage-keyed recovery ledger now
  persists the rolling crash window beneath Application Support with `0600`
  permissions and advisory locking. Decisions are atomic across Parallax
  processes. Corrupt evidence is preserved and automatic recovery fails closed.
  Restart/multi-store circuit and corrupt-ledger regression tests pass. Full
  suite at `a85f70e`: 1,899 tests, 0 failures, 1 documented capability skip.

## PRX-020 — Unchecked Sendable escapes were undocumented and mostly unnecessary

- **Category:** Concurrency correctness / Maintainability
- **Status:** Verified
- **Severity:** P3
- **Likelihood:** Low today; medium over time as fields are added
- **Confidence:** High
- **Evidence:** Before the fix, 45 `@unchecked Sendable` conformances across
  28 files under `Sources/Parallax/`. Two compile probes against throwaway
  package copies showed that 18 already satisfied checked `Sendable`
  structurally and that only 21 were required at all, so 24 compiled in both
  the library and test targets with no conformance. A stored-property and
  lock-coverage scan found zero unguarded accesses in every lock-based type,
  and 26 of the 45 types held no mutable state. Five conformances existed only
  because `any Error` was once non-`Sendable`; the rest traced to bare
  closure fields, a stored `FileManager`, a stored `Timer`, a stored
  `pthread_t`, and two intentionally unguarded scratch types.
- **Affected components:** launch tracking and supervision, settings mutation
  lock and publication, library and profile-data transactions, storage
  relocation, provider subprocess and Codex app-server transport, corporate
  usage freshness.
- **Reproduction / scenario:** Compile-time only. Adding a mutable or
  non-`Sendable` stored property to any of the 24 unnecessarily annotated
  types kept the build green while the invariant the escape asserted stopped
  being true. `CodexAppServerSession.send` also issued two unsynchronized
  writes on a shared `FileHandle`, so two concurrent senders could interleave
  JSON-lines frames; every call site happened to confine a session to one task.
- **Impact:** No current defect. Latent risk that a future field addition
  introduced an unchecked data race silently, and three types whose safety
  rested on confinement recorded nowhere.
- **Root cause:** `@unchecked Sendable` was the default way to satisfy
  `Sendable` constraints rather than a deliberate, justified escape, and some
  annotations predated Foundation and stdlib types gaining `Sendable`.
- **Proposed fix:** Delete the timer token's conformance; lock
  `LifecycleObserverBag.deinit`; serialize `CodexAppServerSession` writes and
  close under one lock; annotate injected closure fields `@Sendable`; drop the
  stored `FileManager`; convert every structurally checked conformance to
  checked `Sendable`; document the survivors that hold unguarded or
  thread-confined state on purpose.
- **Required tests:** A warning-clean full-suite run per step (the compiler is
  the test for the conversions); a coordinator deallocation test with observer
  registrations outstanding; Codex-session tests for concurrent sends keeping
  framing intact and for a send racing `close` throwing `.notRunning`.
- **Dependencies:** `LibraryBackupStore` and its file-access helper had to
  become `Sendable` before `LibraryBackupHook` could.
- **Estimated complexity:** Medium
- **Resolution / verification:** Applied in `7e932db`. The conformance count fell
  from 45 to 20. Each survivor is either guarded by an `NSLock` or
  `NSCondition` on every access (16), a settings lease whose stored
  `pthread_t` blocks checked conformance behind a fail-closed owner-thread
  gate (2), or a deliberately unguarded scratch type whose confinement is now
  stated in a rationale comment (2). `CodexAppServerSession` gained a write
  lock and two regression tests; reverting only the locked write made the
  framing test fail. The full warning-clean suite passed with 1,264 tests and
  the Thread Sanitizer lane passed with zero diagnostics on the fixed tree.
  Update, counted with `git grep -n "@unchecked Sendable" <sha> -- Sources/`:
  20 conformances at `7e932db` and `e6123cf`, 29 at `84b67f7`, and 30 at
  `09a7950` and `675b029`. All 20 survivors remain. The audit fixes added
  10: `WorkspaceReturnedProcessInspection`, `ExpectedProcessTerminationIntent`,
  `ProcessWideLaunchSupervision`, and `ProfileActivityReservation` in
  `1da37d0`; `ProviderPipeReader` and `ProviderProcessRegistry` in `0d8b579`;
  `SettingsMutationCoordinator` (previously an actor),
  `SettingsPendingMutation`, and `SettingsLifecycleObservers` in `4202867`; and
  `ApplicationRemovalRecoveryAttempts` in `3df9f45`. Read at `675b029`, eight
  of them keep their mutable state behind an `NSLock`, and
  `SettingsLifecycleObservers` holds only an immutable array of observer
  tokens. **Flag:** `ProfileActivityReservation` has no
  mutable state and no rationale comment; it should be tried as checked
  `Sendable`. **Flag:** the `e6123cf` split widened four survivors.
  `SettingsPrimaryLockedInspectionLease` and
  `SettingsPrimaryMutationAuthorityLease` went from `fileprivate` to internal;
  their owner-thread gate is unchanged. `Resources` and `PublicationResources`
  went from `private` to internal, so access control no longer enforces the
  locality their rationale comments rely on.

## PRX-021 — Recovery could race a live data operation

- **Category:** Data integrity / Concurrency
- **Status:** Verified
- **Severity:** P0
- **Likelihood:** Low to medium; needs a second window or process
- **Confidence:** High
- **Evidence:** Audit finding 1 and the leads on launches during data
  operations. Each new window recovered journals without the library lock.
  Removal published its manifest before locking. The relocation executor never
  re-checked its receipt, and nothing reserved the spaces involved, so a space
  could be opened while its data was changing.
- **Affected components:** startup recovery (`LibraryStore+Persistence.swift`,
  `LibraryStore+StartupRecovery.swift`), the relocation executor, application
  removal, `ProfileActivityRegistry`.
- **Reproduction / scenario:** Open a new window while a large relocation is
  hashing.
- **Impact:** Both copies of an application's data could be deleted.
- **Root cause:** Recovery and live operations did not exclude each other.
- **Proposed fix:** Recover only under a non-blocking try-lock. Re-check
  receipts before the commit and before each source delete, recover only the
  failed transaction, and reserve the spaces for the whole operation,
  including startup recovery. The destructive override can pass a live launch
  but never another reservation. While recovery waits, keep the spaces it
  involves closed.
- **Required tests:** a second store mid-operation; a changed receipt; a
  reservation checked against launch and against the override; startup
  recovery under a reservation conflict.
- **Dependencies:** None
- **Estimated complexity:** Large
- **Resolution / verification:** Fixed in `edfa888`, `1da37d0`, `84b67f7`,
  `6fb1250`, `3df9f45`, `09a7950`, and `9d06db8`. Since `9d06db8`, startup
  recovery holds the data-operation reservation for every space it touches,
  and a reservation conflict, a space that is still open, or a busy activity
  lock is shown as an operation in progress and retried instead of as library
  damage (`LibraryStore.isRecoveryOperationInProgress`). `f5af87d`
  refuses to open a space that a pending transaction involves while recovery
  waits, keeps unrelated error messages when a busy reload retries, stops
  counting reservation conflicts as failed application-removal recovery
  attempts, and makes profile-data recovery use the store's
  `ProfileActivityRegistry` instead of creating its own, so it sees in-process
  launch leases. Tests:
  `LibraryCoreAuditRegressionTests.testNewStoreDuringLiveRelocationPreservesPublishedData`,
  `StorageRelocationAuditRegressionTests.testReceiptBeforeCommitPreservesSourceAndPriorLibrary`,
  `ApplicationRemovalAuditRegressionTests.testManifestIsPublishedOnlyAfterMutationLockAcquired`,
  `ProfileReservationRevisionAuditRegressionTests.testDestructiveOverrideAllowsLiveLaunchButNeverAnotherReservation`,
  `IntegrationRecoveryAuditRegressionTests.testStartupRemovalReservesEveryManifestProfileDuringRecovery`,
  `IntegrationRecoveryAuditRegressionTests.testStartupRelocationReservationConflictRetries`,
  `ProfileDataAuditRegressionTests.testStartupActiveProfileRecoveryWaitsWithoutDamagingLibrary`,
  `ProfileDataAuditRegressionTests.testStartupProfileActivityLockContentionIsRetryable`;
  added in `f5af87d`:
  `IntegrationDeferredRecoveryAuditRegressionTests.testDeferredRelocationBlocksLaunchAndPreservesUnrelatedError`,
  `IntegrationDeferredRecoveryAuditRegressionTests.testRemovalReservationConflictsAreNotFailedRecoveryAttempts`.
  The registry change has no dedicated test; the profile-data suites exercise
  it through an injected registry. Full suite at `a85f70e`:
  1,899 tests, 0 failures, 1 documented capability skip.

## PRX-022 — Transaction journals could keep the library in recovery on every launch

- **Category:** Reliability / Data integrity
- **Status:** Verified
- **Severity:** P0
- **Likelihood:** Medium for large Chromium spaces
- **Confidence:** High
- **Evidence:** Audit findings 2, 6, and 7, and the relocation leads. Journals
  embedded full manifests, but reads were capped at 4 MiB, which is roughly
  16,000 files (an estimate). Every load re-read completed plans. Delete
  removed the owner marker first, and removal finalize was not idempotent.
  After the wave-two merge, startup still skipped profile-data maintenance,
  and torn-write repair accepted any file that failed to decode.
- **Affected components:** profile-data, relocation, and application-removal
  journals; startup maintenance.
- **Reproduction / scenario:** Clear a large space, or quit during a delete.
- **Impact:** The library entered recovery on every launch, and Restore and
  Start Over failed.
- **Root cause:** Control files had no size bound, and finalize destroyed its
  own evidence.
- **Proposed fix:** Store digests and counts, and read old journals under
  finite caps. Check receipts first, keep eight completed profile-data
  records, and finish from the recorded intent and tombstones. Run
  maintenance on every locked load. Move aside only control files that an
  interrupted write left empty or unparseable, and repair only ownership
  markers in staging or in a restored source; a complete record that does not
  decode stays fail-closed.
- **Required tests:** oversized legacy journals; interrupted delete; pruning;
  startup maintenance with nothing pending; truncated and incompatible
  records.
- **Dependencies:** None
- **Estimated complexity:** Large
- **Resolution / verification:** Fixed in `6fb1250`, `3df9f45`, `09a7950`, and
  `9d06db8`. Since `9d06db8`, every locked library load runs relocation and
  profile-data maintenance, even when nothing is pending; torn-write repair
  accepts only empty or unparseable control files and ownership markers in
  staging or in a restored source, and quarantined markers stay under
  `<base>/.parallax/Transactions/`, out of space folders. `f5af87d` stops
  marker repair from recreating retired staging. Tests:
  `ProfileDataAuditRegressionTests.testCompletedDiscoveryDoesNotReadPlanOrOldRecords`,
  `StorageRelocationAuditRegressionTests.testLargeManifestPlanRemainsBoundedAndDiscoverable`,
  `ProfileDataAuditRegressionTests.testInterruptedDeleteWithRemovedPayloadMarkerCanFinish`,
  `ApplicationRemovalAuditRegressionTests.testDeleteInterruptionDuringPurgeResumesWithoutOwnerMarker`,
  `IntegrationRecoveryAuditRegressionTests.testStartupRelocationMaintenanceRunsWithoutPendingPlans`,
  `ProfileDataAuditRegressionTests.testStartupSweepsProfileTemporaryWithoutPendingTransaction`,
  `ProfileDataAuditRegressionTests.testCompleteIncompatibleJSONIsNeverTorn`,
  `ProfileDataAuditRegressionTests.testPrefixMarkerInPublishedFolderCannotAuthorizeRollback`,
  `ProfileDataAuditRegressionTests.testPayloadMarkerQuarantineStaysInTransactionStaging`;
  added in `f5af87d`:
  `ProfileDataAuditRegressionTests.testRestoredSourceMarkerRepairWithoutStagingDirectory`.
  Full suite at `a85f70e`: 1,899 tests, 0 failures, 1 documented capability skip.

## PRX-023 — Data operations failed, orphaned data, or misreported ordinary cases

- **Category:** Reliability / Data integrity / UX
- **Status:** Verified
- **Severity:** P1
- **Likelihood:** High; a space that was never opened could not be removed
- **Confidence:** High
- **Evidence:** Audit findings 9, 10, and 11, and the removal and relocation
  leads. A missing folder made `realpath` fail, Remove Space Only refused its
  own busy flag, and Reveal showed an empty alert. Removal failed with an
  opaque error when there was no base root. Relocation orphaned data behind
  explicit paths and hashed on the main actor, contrary to PRX-015. After the
  wave-two merge, application-removal recovery was unreachable after Close or
  a relaunch, leftover-data notices never appeared at startup, data actions
  ignored an external `CLAUDE_CONFIG_DIR`, and "Change…" stayed enabled while
  a relocation ran.
- **Affected components:** `LibraryStore+Destructive*.swift`, removal and
  relocation coordinators, `EmptyStates`, `ContentView`,
  `ApplicationHeaderView`.
- **Reproduction / scenario:** Remove a space that was never opened, or
  relocate a space with an explicit `--user-data-dir` inside managed storage.
- **Impact:** Raw errors, removals that could not finish, and data orphaned
  by a move that reported success.
- **Root cause:** Paths were assumed to exist, and explicit paths were treated
  as external.
- **Proposed fix:** Fall back to the standardized path, refuse unavailable
  storage, and add Keep Files and Continue, reachable after Close and
  relaunch. Prepare relocation previews off the main thread, with
  cancellation, name every blocker, and report original data left in place
  until the user dismisses the notice.
- **Required tests:** each action on a missing folder; an offline volume;
  Keep Files after a relaunch; relocation blockers; leftover notices.
- **Dependencies:** None
- **Estimated complexity:** Large
- **Resolution / verification:** Fixed in `6193668`, `6fb1250`, `3df9f45`,
  `09a7950`, and `9d06db8`. Since `9d06db8`, application-removal recovery,
  including Keep Files and Continue, stays reachable from the library recovery
  screen after Close or a relaunch, and Start Over is not offered; startup
  shows relocation leftover notices; data actions report an external
  `CLAUDE_CONFIG_DIR`; and "Change…" is disabled during a relocation.
  `f5af87d` shows each leftover notice once per window, removes it for
  good when it is dismissed, and ignores an unreadable notice instead of
  entering library recovery. Tests:
  `ProfileDataAuditRegressionTests.testMissingFolderCanBeConfirmedForEveryProfileAction`,
  `ProfileDataAuditRegressionTests.testAsyncRemoveSpaceOnlySucceedsAndDoesNotSelectAnotherSpace`,
  `ManagedRevealAuditRegressionTests.testConfiguredManagedPathsRevealForGeneratedAndExplicitOwnership`,
  `ApplicationRemovalReviewAuditRegressionTests.testKeepFilesRetiresOnlyReviewedJournalAndPreservesEveryCopy`,
  `StorageRelocationAuditRegressionTests.testExplicitManagedUserDataIsBlockedInsteadOfPreservedAsExternal`,
  `IntegrationRecoveryAuditRegressionTests.testRemovalConflictSurvivesCloseRelaunchAndPeerReload`,
  `IntegrationRecoveryAuditRegressionTests.testStartupShowsRecordedRelocationLeftovers`
  (updated in `f5af87d`),
  `ProfileDataAuditRegressionTests.testExternalClaudeConfigurationIsReported`;
  added in `f5af87d`:
  `IntegrationDeferredRecoveryAuditRegressionTests.testRelocationNoticeIsPresentedOnceAndDismissalWaitsForLibraryLock`,
  `IntegrationDeferredRecoveryAuditRegressionTests.testDamagedLeftoverNoticeDoesNotRequireLibraryRecovery`.
  The recovery-button placement and the disabled "Change…" button are checked
  only by reading view source
  (`IntegrationRecoveryAuditRegressionTests.testRecoveryControlsRemainReachableAndRelocationChangeIsDisabled`);
  there is no UI test target (PRX-016). Full suite at `a85f70e`:
  1,899 tests, 0 failures, 1 documented capability skip.

## PRX-024 — One failed legacy migration blocked migration permanently

- **Category:** Reliability / Data integrity
- **Status:** Verified
- **Severity:** P1
- **Likelihood:** Low to medium
- **Confidence:** High
- **Evidence:** Audit finding 8 and the migration and backup leads. A retry
  resumed the rolled-back journal and required its manifests to be unchanged.
  Stale temporary files blocked retries, and backups were pruned by
  wall-clock time.
- **Affected components:** `LibraryMigrationCoordinator*.swift`,
  `LibraryBackupStore*.swift`.
- **Reproduction / scenario:** Let a migration roll back, change a legacy
  profile, and reopen.
- **Impact:** `invalidJournal` on every attempt; only Start Over got past it.
- **Root cause:** A retry reused a stale plan.
- **Proposed fix:** Retire the rolled-back journal and plan again with the
  journaled IDs. Ignore stale temporary files. Order and prune backups by
  publication sequence, under a lock shared across processes.
- **Required tests:** retry after a change; clock rollback; concurrent
  publishers.
- **Dependencies:** None
- **Estimated complexity:** Medium
- **Resolution / verification:** Fixed in `edfa888` and `983307d`. Tests:
  `LibraryMigrationAuditRegressionTests.testRetryAfterSourceChangedReplansWithJournaledIDs`,
  `LibraryMigrationRecoveryAuditRegressionTests.testChangedLegacyHashAfterSuccessfulRollbackRetiresOldJournal`,
  `LibraryCoreAuditRegressionTests.testMigrationBlockerMessageIncludesReasonAndPath`,
  `LibraryBackupAuditRegressionTests.testClockRollbackKeepsPublishedBackupAndRestoresLatestPublication`.
  Full suite at `a85f70e`: 1,899 tests, 0 failures, 1 documented capability skip.

## PRX-025 — Launch configuration crashed, leaked secrets, or ignored isolation paths

- **Category:** Reliability / Security / Isolation
- **Status:** Verified
- **Severity:** P0
- **Likelihood:** Medium
- **Confidence:** High
- **Evidence:** Audit findings 3, 12, 13, 17, 18, and 19, and a reviewer lead
  that `CLAUDE_CONFIG_DIR` was not treated as an isolation path. A bare `--`
  crashed the app. The split `--user-data-dir` form and editor-typed paths
  were ignored. U+2028 hid an assignment from review, some credential values
  escaped detection, and Duplicate shared `CLAUDE_CONFIG_DIR`.
- **Affected components:** the launch parsers, `SensitiveLaunchArgumentPolicy`,
  `LaunchIsolationAnalyzer`, launch health, import review.
- **Reproduction / scenario:** Add `--` or `--db-url=postgres://u:pw@db`, or
  open a Claude space and its duplicate.
- **Impact:** Crashes, a real profile used as if isolated, and exported
  secrets.
- **Root cause:** The parser, rewriter, and classifier used different models.
- **Proposed fix:** Emit `--user-data-dir=<path>` before `--`. Block
  alternative newlines, classify values after `=`, and treat edited paths as
  explicit. For Claude presets only, give each duplicate its own folder and
  block collisions.
- **Required tests:** each trigger above; custom presets unaffected.
- **Dependencies:** None
- **Estimated complexity:** Medium
- **Resolution / verification:** Fixed in `57f11c6`, `84b67f7`, `74b2913`, and
  `e887fb7`. Tests:
  `LaunchConfigurationAuditRegressionTests.testDashOnlyArgumentsDoNotCrashSecretClassification`,
  `LaunchConfigurationAuditRegressionTests.testSplitSwitchIsEmittedAsOneEqualsToken`,
  `LaunchEditingAuditRegressionTests.testEditorIsolationEditsBecomeExplicitAndPersist`,
  `LaunchConfigurationAuditRegressionTests.testCredentialOptionValuesAndCamelCaseOptionsAreSensitive`,
  `ClaudeIsolationFollowupAuditRegressionTests.testClaudeDuplicateDropsAllExplicitConfigEntriesAndKeepsOtherText`,
  `ClaudeIsolationFollowupAuditRegressionTests.testClaudePeerCollisionUsesExpandedPathAndCannotBeOverridden`.
  Full suite at `a85f70e`: 1,899 tests, 0 failures, 1 documented capability skip.

## PRX-026 — Settings persistence crashed or entered recovery on ordinary edits

- **Category:** Reliability / Data integrity
- **Status:** Verified
- **Severity:** P0
- **Likelihood:** Medium
- **Confidence:** High
- **Evidence:** Audit findings 4, 22, 23, 25, 26, and 27. Export Preserved Copy
  crashed. Oversized edits and unrelated writes forced recovery. Alerts hid
  their message, a U+FEFF character was lost, and every commit left a hidden
  copy behind.
- **Affected components:** the settings coordinator, lock, and publication;
  `StrictJSONLexical`; `AppSettings`.
- **Reproduction / scenario:** Paste 64 KiB into a template field.
- **Impact:** A crash, or launches and edits blocked until relaunch.
- **Root cause:** Invalid write options, and rejected edits treated as
  recovery.
- **Proposed fix:** Write with `.atomic` only, and reject oversized edits
  before queueing them. Compare file identity instead of timestamps, unlink
  prior copies once proven, and debounce text fields by 400 ms.
- **Required tests:** each trigger above.
- **Dependencies:** None
- **Estimated complexity:** Medium
- **Resolution / verification:** Fixed in `4202867` and `84b67f7`. Tests:
  `SettingsAuditRegressionTests.testFailedPreservedExportCanBeRetriedAndOnlySuccessDismisses`,
  `SettingsAuditRegressionTests.testOversizedEditsRevertBeforeEnqueueAndOtherSettingsStillCommit`,
  `SettingsAuditRegressionTests.testSiblingContainerWriteDoesNotInvalidateCommit`,
  `SettingsAuditRegressionTests.testBOMInValuesRoundTripsAndBOMKeysRemainDistinct`,
  `SettingsAuditRegressionTests.testSuccessfulSwapDoesNotRetainPriorSettings`.
  Full suite at `a85f70e`: 1,899 tests, 0 failures, 1 documented capability skip.

## PRX-027 — Editor, Keychain, import, and export lost or leaked user intent

- **Category:** Data integrity / Security / UX
- **Status:** Verified
- **Severity:** P1
- **Likelihood:** Medium
- **Confidence:** High
- **Evidence:** Audit findings 20, 21, 24, 30, and 31. Removing a Keychain
  variable deleted an item a duplicate used. Discard followed by Open
  launched a stale draft. "Use Imported" moved storage roots without their
  data. Editor saves bypassed `canMutateLibrary()`. Exporting in recovery
  wrote an empty library. After the wave-two merge, a backup-publication
  timeout during an import replacement was handled as a failed replacement,
  so another window's newer save could be misread as damage.
- **Affected components:** `ProfileEditorSession`, `LibraryStore+ProfileData`,
  the import transformer, import replacement recovery
  (`LibraryImportReplacementRecovery`), portability.
- **Reproduction / scenario:** Remove a Keychain variable from one of two
  duplicates.
- **Impact:** Lost secrets, orphaned data, and empty exports reported as a
  success.
- **Root cause:** Reference counts were kept per window, and authority checks
  were missing.
- **Proposed fix:** Delete a Keychain item only when nothing references it.
  Rebase Discard on the saved row, keep known storage roots on import, require
  library authority for saves and exports, and treat a publication timeout as
  happening before the import took effect.
- **Required tests:** shared references; stale discard; exports; a
  publication timeout followed by a peer save.
- **Dependencies:** None
- **Estimated complexity:** Medium
- **Resolution / verification:** Fixed in `46a9b5b`, `57f11c6`, `be39a31`,
  `84b67f7`, `09a7950`, and `9d06db8`. Tests:
  `EditorSessionAuditRegressionTests.testSavingRemovalRetainsSecretUsedByDuplicate`,
  `EditorSessionAuditRegressionTests.testDiscardAndCleanOpenResolveCurrentPersistedProfile`,
  `LibraryTransferAuditRegressionTests.testUseImportedPreservesStorageAndRequiresReviewForRetargetedSpaces`,
  `LibraryTransferAuditRegressionTests.testLibraryExportsRequireLoadedState`,
  `IntegrationImportRecoveryAuditRegressionTests.testBackupPublicationTimeoutDoesNotRecoverPeerWrite`.
  Full suite at `a85f70e`: 1,899 tests, 0 failures, 1 documented capability skip.

## PRX-028 — Account tracking misreported sign-in and refresh state

- **Category:** Reliability / UX (preview surface)
- **Status:** Verified
- **Severity:** P1
- **Likelihood:** Medium
- **Confidence:** High
- **Evidence:** Audit finding 15 and the account leads. A Claude sign-in the
  provider confirmed was shown as "Sign-in failed" whenever `/usage` failed.
  Checks ran every 15–20 minutes instead of about every 5, and timeouts left
  process groups running.
- **Affected components:** `AIAccountConnectionService*`, `ProviderSubprocess`.
- **Reproduction / scenario:** Sign in to Claude while `/usage` fails.
- **Impact:** The preview contradicted its documented refresh policy.
- **Root cause:** Authentication and usage results were treated as one.
- **Proposed fix:** Keep confirmed sign-ins connected, check accounts every 5
  minutes, kill whole process groups, and run Codex sign-ins one at a time.
- **Required tests:** as above.
- **Dependencies:** Provider tools installed locally.
- **Estimated complexity:** Medium
- **Resolution / verification:** Fixed in `0d8b579`. Tests:
  `ProviderAccountAuditRegressionTests.testConfirmedClaudeAuthenticationSurvivesEveryUsageFailure`,
  `AccountsAuditRegressionTests.testHealthyAccountIsDueAtFiveMinutes`,
  `AccountsAuditRegressionTests.testCodexSignInsSerializeButRefreshesRemainIndependent`,
  `ProviderSubprocessAuditRegressionTests.testCancellationStopsTheProviderProcessGroup`.
  Full suite at `a85f70e`: 1,899 tests, 0 failures, 1 documented capability skip.

## PRX-029 — Launch records and lifecycle could block spaces or hide crashes

- **Category:** Reliability / Observability
- **Status:** Verified
- **Severity:** P1
- **Likelihood:** Low to medium
- **Confidence:** High
- **Evidence:** Audit findings 5, 14, and 32, and a reviewer lead that an exit
  right after final verification lost crash handling. A crash during a
  journal write locked every launch. A declined Quit left the space
  "terminating". Queued launches received durable "opening" receipts. After
  an open error with an unknown outcome, later opens of the same app showed
  "Opening…" until Parallax restarted.
- **Affected components:** the durable activity store and codec,
  `TrackedLaunchSession`, `WorkspaceApplicationLaunchAuthority`,
  `ProfileActivityRegistry`, `LaunchStatusPresenter`, stuck-launch recovery.
- **Reproduction / scenario:** Force Quit during an open, or cancel "Save
  changes?" after Quit.
- **Impact:** A lockout of the whole library, crashes counted as expected
  exits, and waits without explanation.
- **Root cause:** Aborted writes were read as global corruption, the
  lifecycle state was never restored, and a retained submission slot had no
  user-directed release.
- **Proposed fix:** Sweep aborted writes, limit corruption to one space,
  restore the lifecycle after the grace period, and add Clear Stuck Launch
  Record. Show queued opens as waiting, name the blocking space, and let a
  confirmed clear retire that exact open, release the queue, and record the
  open as cancelled.
- **Required tests:** as above; no release while a matching process runs.
- **Dependencies:** None
- **Estimated complexity:** Large
- **Resolution / verification:** Fixed in `1da37d0`, `84b67f7`, `e887fb7`,
  `74b2913`, and `9d06db8`. Since `9d06db8`, opens queued behind an unknown
  outcome show a waiting state, and confirming Clear Stuck Launch Record
  retires that exact open and releases the queue only when no matching app
  runs and the space still points at the bundle that was opened.
  `f5af87d` offers the action only for that bundle, names the blocking
  space in waiting messages, restores the restart guidance in the error
  message, resumes the next queued open off the main thread so a busy
  activity lock does not fail it, and records the cleared open as cancelled
  ("Open cancelled") in the lifecycle, the UI, and launch history. While
  startup recovery waits on a stuck record, it names that space and allows
  clearing it. Tests:
  `DurableActivityAuditRegressionTests.testEmptyAndTempOnlyDirectoriesAreAbortedCreates`,
  `LaunchSessionAuditRegressionTests.testDeclinedQuitRestoresRunningAndLaterExitIsUnexpected`,
  `LaunchSessionAuditRegressionTests.testQueuedLaunchHasNoOpeningMarkerBeforeSubmission`,
  `LaunchLifecycleFollowupAuditRegressionTests.testExitAfterFinalVerificationRetainsIdentityAndUnexpectedTermination`,
  `IntegrationLaunchQueueAuditRegressionTests.testUnknownOpenWaitsAndConfirmedClearReleasesExactSlot`
  (extended in `f5af87d`),
  `LaunchLifecycleFollowupAuditRegressionTests.testUnknownOpenOutcomeMessagePointsToConfirmedRecordRecovery`
  (updated in `f5af87d`); added in `f5af87d`:
  `IntegrationLaunchClearAuditRegressionTests.testClearedQueueResumesOffMainThreadThroughActivityLockContention`,
  `ProfileDataAuditRegressionTests.testPendingProfileTransactionCanClearItsBlockingOpeningRecord`.
  The `cancelled` encoding added in `f5af87d` was not readable by earlier
  builds; `d09732e` adds compatible persistence (PRX-036). Earlier full suite
  at `a85f70e`: 1,899 tests, 0 failures, 1 documented capability skip.

## PRX-030 — Recursive filesystem work could leave managed storage or race

- **Category:** Security / Data integrity
- **Status:** Verified. Volume identity is resolved in `d09732e` (PRX-034).
- **Severity:** P2
- **Likelihood:** Low
- **Confidence:** High
- **Evidence:** Audit finding 34 and the filesystem leads. Walks had no device
  check, copy reopened destinations by name, a FIFO could block the
  operation, and owned removal deleted by path.
- **Affected components:** `SecureManagedFileSystem*`, `FileSystem`,
  `ManagedPathResolver`.
- **Reproduction / scenario:** Mount a volume inside a profile, then Delete.
- **Impact:** Files outside managed storage could be deleted.
- **Root cause:** Checks used paths that could change between inspection and
  effect.
- **Proposed fix:** Refuse items on other devices, write through the
  descriptors Parallax created, and verify identity after the first write,
  because FAT32 and exFAT assign file IDs late. Require owned namespace
  folders with no ACLs, and remove group and world write access from them.
- **Required tests:** another device; hard-link swap; FIFO; modes and ACLs.
- **Dependencies:** None
- **Estimated complexity:** Large
- **Resolution / verification:** Fixed in `6193668`. Tests:
  `SecureFilesystemAuditRegressionTests.testAllWalkersRejectAnItemOnAnotherDevice`,
  `SecureFilesystemAuditRegressionTests.testCopyDoesNotWriteThroughSwappedDestinationHardLink`,
  `SecureFilesystemAuditRegressionTests.testManifestCopyAndRenameFileOpensCannotBlockOnFIFO`,
  `FilesystemReviewAuditRegressionTests.testACLNamespaceIsRejectedWithoutTighteningAndNamesItsPath`.
  The late-file-ID case has only a synthetic test
  (`FilesystemReviewAuditRegressionTests.testCopyAcceptsFileIdentityAssignedOnFirstWrite`);
  FAT32 and exFAT volumes are not tested and are not documented as supported.
  Full suite at `a85f70e`: 1,899 tests, 0 failures, 1 documented capability skip.

## PRX-031 — Selection fell back to the first item and window actions misfired

- **Category:** UX / Convention (AGENTS.md)
- **Status:** Verified. Tests for audit findings 16 and 33(c) were added in
  `75d4a3e` (PRX-038).
- **Severity:** P1
- **Likelihood:** High
- **Confidence:** High for selection and presentation logic; native UI
  rendering remains a manual check
- **Evidence:** Audit findings 16, 29, and 33. The count from
  `git grep -c '\.first?\.id' -- Sources/Parallax` is 27 at `e6123cf` and 0 at
  `09a7950` and `675b029`. "Choose an App" did nothing on the Control Center
  tab.
- **Affected components:** selection in `LibraryStore+*.swift`, `ContentView`,
  the menu bar, `NewSpaceView`.
- **Reproduction / scenario:** Remove the selected space.
- **Impact:** Actions applied to an item the user had not chosen.
- **Root cause:** Selection defaulted to the first item, and the importer was
  in an unselected tab.
- **Proposed fix:** Keep a surviving selection, or clear it. Move the importer
  to `ContentView`, and track windows by reference.
- **Required tests:** selection after each mutation; window lookup.
- **Dependencies:** None
- **Estimated complexity:** Medium
- **Resolution / verification:** Fixed in `edfa888`, `be39a31`, `46a9b5b`,
  `6fb1250`, `3df9f45`, and `09a7950`. Tests:
  `LibraryCoreAuditRegressionTests.testLoadPreservesValidSelectionAndNeverSelectsFirstItem`,
  `ApplicationRemovalFlowAuditRegressionTests.testRemovalPreservesSurvivingSelectionAndClearsRemovedSelection`,
  `StorageRelocationAuditRegressionTests.testSuccessKeepsMissingSelectionNil`,
  `EditorSceneAuditRegressionTests.testWindowLookupUsesVisibilityAndMiniaturizationNotTitle`,
  `EditorViewsAuditRegressionTests.testNewSpaceWithoutPreferenceDefaultsToWork`.
  Full suite at `a85f70e`: 1,899 tests, 0 failures, 1 documented capability skip.

## PRX-032 — Localization had missing keys, wrong specifiers, and mistranslations

- **Category:** UX / Localization
- **Status:** Verified
- **Severity:** P2
- **Likelihood:** High for Spanish users
- **Confidence:** High
- **Evidence:** Audit finding 28 (drift item 3 for PRX-016). Recovery strings
  were missing, and `pid_t` messages used `%d` keys that did not exist.
  Spanish stored "Trabajar" as the name of the Work template. After the
  wave-two merge, some new Spanish entries used the informal register, and
  `IntegrationFollowupAuditRegressionTests.testSpanishCatalogUsesFormalRegister`
  failed at `09a7950`.
- **Affected components:** both catalogs; the localization checker.
- **Reproduction / scenario:** Use Spanish, then trigger recovery.
- **Impact:** Wrong text, while the census still passed.
- **Root cause:** The extractor missed initializers, ternaries, and switches.
- **Proposed fix:** Extend the extractor and fail closed, then fix the
  catalogs. Keep saved template names; Reset to Defaults applies the
  corrected ones.
- **Required tests:** extractor contracts; template compatibility; catalog
  hygiene and register.
- **Dependencies:** None
- **Estimated complexity:** Medium
- **Resolution / verification:** Fixed in `2cd6140`, with strings in
  `84b67f7`, `e887fb7`, `6193668`, `09a7950`, and `9d06db8`.
  `f5af87d` makes the register check case-insensitive, extends it to
  more informal imperatives and pronouns, and corrects the entries it found.
  Tests:
  `GateLocalizationAuditRegressionTests.testProcessIdentifierUsesInt32CatalogKey`,
  `LocalizationAuditRegressionTests.test_initializer_memberwise_ternary_and_returned_keys`,
  `SettingsTemplateFollowupAuditRegressionTests.testHistoricalSpanishTemplatesLoadAndCommitWithoutRewriting`,
  `IntegrationFollowupAuditRegressionTests.testSpanishCatalogUsesFormalRegister`,
  `IntegrationCatalogAuditRegressionTests.testMergedCatalogsHaveUniqueKeysNoBlankLinesAndNoRetiredKeys`
  (extended in `f5af87d`). Localization census at `a85f70e`:
  1,203 source keys; 1,206 English and 1,206 Spanish entries, zero debt. Full suite at `a85f70e`: 1,899 tests, 0 failures, 1 documented capability skip.

## PRX-033 — Local gates were broken or could pass without checking

- **Category:** Build / Testing
- **Status:** Verified
- **Severity:** P1
- **Likelihood:** Certain on Swift 6.4 (finding 36)
- **Confidence:** High
- **Evidence:** Audit findings 35, 36, and 37, and the script leads. Coverage
  and packaging assumed the native build layout. The diff gate looked only at
  the working tree. Release builds missed ignored inputs, and a failed lock
  deleted the other process's lock.
- **Affected components:** `run_quality_gates.sh`, `check_coverage.sh`,
  `check_git_state.py`, `script/lib/build_and_run/`.
- **Reproduction / scenario:** Commit on Swift 6.4, then run the full gates.
- **Impact:** The gates could not pass, or passed without checking anything.
- **Root cause:** Toolchain assumptions, and checks limited to the working
  tree.
- **Proposed fix:** Pin `--build-system native`, diff-check commits, and
  release from `git archive`. Use kernel locks, and bound the re-inspection
  of a launched process.
- **Required tests:** Python gate contracts; re-inspection tests.
- **Dependencies:** A toolchain that includes the native build system.
- **Estimated complexity:** Medium
- **Resolution / verification:** Fixed in `2cd6140`, `1da37d0`, and
  `e887fb7`; the coverage floor is raised in this change (PRX-038). Tests:
  `GateAuditRegressionTests.test_native_build_layout_is_explicit`,
  `GateAuditRegressionTests.test_committed_staged_and_unstaged_whitespace`,
  `GateAuditRegressionTests.test_release_compiles_committed_snapshot`,
  `ReinspectionReviewAuditRegressionTests.testMissingMetadataIsRetriedBeforeProvenanceIsClassified`.
  Gates at `a85f70e`: PASS.

## PRX-034 — Storage volumes are identified by device number or by /Volumes alone

- **Category:** Reliability / Data integrity
- **Status:** Verified
- **Severity:** P2
- **Likelihood:** Low; affects external drives and custom mount points
- **Confidence:** High for the code and synthetic recovery tests
- **Evidence:** Profile-data and relocation recovery previously compared
  device numbers that can change after a replug. Missing-root detection
  recognized unplugged drives only under `/Volumes`. New
  `StorageTransactionRootBinding` records the root inode and volume UUID;
  `StorageVolumeEnrollmentStore` remembers the configured base path and UUID
  separately from `library.json`. A missing enrolled root is unavailable when
  its recorded volume is not mounted, including outside `/Volumes`.
- **Affected components:** profile-data and relocation recovery; launch
  preparation; volume enrollment and recovery presentation.
- **Reproduction / scenario:** Reconnect a drive under a new device number
  after an interrupted Clear. Or unmount a volume mounted outside `/Volumes`
  and then open its space.
- **Impact:** Recovery previously stopped without deleting anything and could
  not finish, or launch could create empty folders on the mount point's disk.
- **Root cause:** No stable, persisted identity for the volume.
- **Proposed fix:** Record the volume UUID with the inode, keep reading old
  records, and remember the expected volume for missing-root checks.
- **Required tests:** changed device with the same UUID; different volume or
  inode; legacy records; missing custom mount point; advisory sidecar failure;
  recovery branches that do not need the source or destination; confirmed
  forgetting without data or metadata changes.
- **Dependencies:** Legacy records retain device checks. UUID-less recovery
  retains inode and ownership checks; enrollment is advisory.
- **Estimated complexity:** Medium
- **Resolution / verification:** Implemented in `d09732e`. Recovery binds only
  roots its branch reads or changes; a verified committed relocation can
  leave unavailable source data in place. Enrollment failures do not prevent
  completion or recovery. Forget This Drive removes only the application's
  enrollment after confirmation, not data, metadata, or transaction authority.
  Tests: `ExternalDriveAuditRegressionTests`,
  `VolumeRecoveryAuditRegressionTests`, `RelocationRootBranchAuditRegressionTests`,
  `StorageEnrollmentReviewAuditRegressionTests`,
  `ForgetStorageVolumeAuditRegressionTests`, and
  `StorageVolumeRecoveryPresentationTests`. Full suite at `8c88e71`:
  2,121 tests, 0 failures, 2 skipped. See `docs/MIGRATION_AND_RECOVERY.md`
  for missing-root and UUID-availability limits.

## PRX-035 — Relocation to HFS+ fails for names that HFS+ normalizes

- **Category:** Compatibility
- **Status:** Open
- **Severity:** P3
- **Likelihood:** Low
- **Confidence:** Medium; read in the code, not run on HFS+
- **Evidence:** `SecureManagedFileSystem.copyTree`
  (`Support/SecureManagedFileSystem+CopyTree.swift`) compares the raw source
  and destination manifests, while relocation's own manifests compare names
  after `precomposedStringWithCanonicalMapping`
  (`StorageRelocationCoordinator.normalizedManifestEntry`). The failure path
  keeps the source:
  `StorageRelocationReviewAuditRegressionTests.testCopyManifestFailureHasClearErrorAndPreservesSource`.
- **Affected components:** relocation copy verification.
- **Reproduction / scenario:** Relocate a file whose name contains a composed
  accented character from APFS to Mac OS Extended.
- **Impact:** The destination copy cannot be verified; the original is kept.
- **Root cause:** HFS+ stores names in decomposed form.
- **Proposed fix:** Treat canonically equivalent names as equal.
- **Required tests:** composed and decomposed forms of the same name.
- **Dependencies:** None
- **Estimated complexity:** Small
- **Resolution / verification:** Not resolved at `a85f70e`.

## PRX-036 — Earlier builds cannot read records written by this build

- **Category:** Compatibility / Recovery
- **Status:** Verified; unsupported pending records fail closed on downgrade
- **Severity:** P2
- **Likelihood:** Low; only after a downgrade
- **Confidence:** High for record encoding and synthetic decoder tests;
  application rollback is not a data-format rollback
- **Evidence:** At `a85f70e`, completed version-3 profile-data plans and
  version-2 relocation plans remained where `d203594` scanned them, although
  its decoders accepted only versions 2 and 1 respectively. The `cancelled`
  launch-history state added in `f5af87d` also caused older builds to
  quarantine history. Application-removal phases needed an explicit encoding
  boundary to prevent older builds from acting on newer recovery semantics.
- **Affected components:** transaction retirement, application-removal
  journals, launch-history persistence, downgrade documentation.
- **Reproduction / scenario:** Complete a Clear or relocation, or record a
  cancelled launch, then open with an earlier build. Separately, downgrade
  with an application removal still pending.
- **Impact:** Completed records could block the older library load and
  cancellation could hide Recent Activity; newer removal semantics could be
  misread during recovery.
- **Root cause:** Record formats changed without a complete downgrade boundary.
- **Proposed fix:** Retire completed records immediately, persist cancellation
  compatibly, and make older removal decoders reject newer records.
- **Required tests:** completed control-record cleanup; cancelled-history
  round trip and migration; old decoder refusal of v2 removal phases; current
  decoder acceptance of earlier phases.
- **Dependencies:** Unfinished records and deferred cleanup may still require
  a compatible build. General downgrade support is not established.
- **Estimated complexity:** Medium
- **Resolution / verification:** Implemented in `d09732e`.
  `ProfileDataTransactionCoordinator.retainedCompletedTransactions` is zero;
  relocation retires completed plans immediately, with cleanup failures
  deferred. `LaunchHistoryEntry` writes cancelled entries as `closed` plus
  `wasCancelled`, and the store rewrites the earlier encoding on load.
  `ApplicationRemovalTransactionPhase` writes `prepared-v2` and
  `metadataCommitted-v2`, which earlier decoders refuse. Tests:
  `ExternalDriveAuditRegressionTests.testCompletedProfileTransactionsLeaveNoControlRecords`,
  `ExternalDriveAuditRegressionTests.testCompletedRelocationLeavesNoControlRecords`,
  `ExternalDriveAuditRegressionTests.testCancelledHistoryUsesLegacyStateAndStillRoundTrips`,
  `ExternalDriveAuditRegressionTests.testPreviousCancelledHistoryMigratesOnceWithoutLosingEntries`,
  and `ApplicationRemovalDowngradeAuditRegressionTests`. Full suite at
  `8c88e71`: 2,121 tests, 0 failures, 2 skipped. Downgrade limits remain in
  `docs/BUILD_AND_RELEASE.md` and `docs/MIGRATION_AND_RECOVERY.md`.

## PRX-037 — Cross-area gaps after the wave-two merge

- **Category:** Reliability / Recovery / UX
- **Status:** Verified; each item is recorded in the entry it belongs to
- **Severity:** P1
- **Likelihood:** Medium
- **Confidence:** High
- **Evidence:** At `09a7950`, the wave-two fixes were merged, but no single
  fix could change the files the others owned. Startup skipped profile-data
  maintenance, ran relocation maintenance only while a relocation was pending,
  and never showed leftover notices. A reservation conflict during startup
  recovery showed the library recovery screen. Startup recovery of an
  application removal took no reservation. Application-removal recovery was
  unreachable after Close or a relaunch, where generic recovery could offer
  Start Over. Opens queued behind an unknown outcome showed "Opening…" until
  Parallax restarted. Torn-write repair accepted any file that failed to
  decode. Data actions ignored an external `CLAUDE_CONFIG_DIR`, a busy backup
  publication looked like a failed import, and "Change…" stayed enabled during
  a relocation. Two tests failed:
  `IntegrationFinalAuditRegressionTests.testNonLocalizedErrorsAreMappedAtInvocationAndConfirmation`
  and `IntegrationFollowupAuditRegressionTests.testSpanishCatalogUsesFormalRegister`.
- **Affected components:** startup recovery, application-removal recovery
  views, the launch queue, profile-data recovery, the catalogs.
- **Reproduction / scenario:** Relaunch while a removal is pending and its
  rollback conflicts.
- **Impact:** Start Over was offered over a healthy library, and waits
  happened without explanation.
- **Root cause:** The fixes were split by file ownership.
- **Proposed fix:** Integrate the cross-area changes.
- **Required tests:** one per item.
- **Dependencies:** None
- **Estimated complexity:** Medium
- **Resolution / verification:** Fixed in `9d06db8`, with follow-ups in
  `f5af87d`. Reservations, deferred recovery, and profile-data recovery:
  PRX-021. Maintenance and torn-write repair: PRX-022. Removal recovery after
  a relaunch, leftover notices, external `CLAUDE_CONFIG_DIR`, and "Change…":
  PRX-023. The publication timeout: PRX-027. The launch queue and cleared
  opens: PRX-029. The catalogs: PRX-032.
  `IntegrationFinalAuditRegressionTests.testNonLocalizedErrorsAreMappedAtInvocationAndConfirmation`
  now uses a genuinely unlocalized error and also checks that a localized
  secure-filesystem message passes through. Full suite at `a85f70e`:
  1,899 tests, 0 failures, 1 documented capability skip.

## PRX-038 — Gate strength: coverage floor, wall-clock tests, untested fixes

- **Category:** Testing
- **Status:** Verified; native UI rendering remains a manual check (PRX-016).
- **Severity:** P2
- **Likelihood:** Certain for the floor; intermittent for timing
- **Confidence:** High
- **Evidence:** Audit finding 38: the floor stored in
  `script/coverage-baseline.env` was 30,029 of 56,525 lines (53.1252%), about
  11.9 points below the 64.9965% measured at `e6123cf`.
  `CompletionGateLaunchMutationTests.testMissingApplicationBundleIsUnhealthyAndLaunchIsBlocked`
  waited a fixed 1 second, and `ProductionLaunchApplicationFixture` judged
  cleanup 150 ms after sending SIGKILL. The fixes for audit finding 16
  ("Choose an App" did nothing on the Control Center tab; `ContentView` now
  presents the app importer) and finding 33(c) (repeated launch warnings
  shared a `ForEach` identity; they now use their offset), both in `46a9b5b`,
  lacked regression tests at `a85f70e`.
  `Wave8RegressionGapTests.testImporterFailureRemainsOnOriginatingWindowAfterFocusChanges`
  reads the importer callback in `ContentView.swift`, but it passed before the
  fix as well, because the importer was already in that file.
- **Affected components:** the coverage baseline, launch/import/relocation
  tests, `ContentView`, launch-warning presentation.
- **Reproduction / scenario:** Run the full gates under heavy load, or move
  the importer back into the Local Spaces view.
- **Impact:** Coverage could fall about 12 points unnoticed, gates flaked,
  and a regression of either view fix could pass every gate.
- **Root cause:** The floor was frozen until the fixes landed, the tests used
  fixed deadlines, and there is no UI test target (PRX-016).
- **Proposed fix:** Store the lower of two fresh measurements, wait for
  completion instead of time, and add view-model or UI tests for the two view
  fixes.
- **Required tests:** the ratchet at the new floor; tests for findings 16 and
  33(c).
- **Dependencies:** Native view rendering still needs manual verification;
  the presentation seams are covered.
- **Estimated complexity:** Small
- **Resolution / verification:** The floor remains 51,137 / 75,458
  (67.77%, measured at `84b67f7`) in `script/coverage-baseline.env`;
  coverage at `8c88e71` is 58,587 / 84,463 (69.36%). The original fixed waits
  were replaced in `9d06db8`: launch preparation is awaited and fixture cleanup
  polls process termination with a 30-second bound. `d09732e` makes relocation
  cancellation wait for a staging event and task completion, awaits launch
  preparation before lifecycle checks, and gives the existing profile-data
  commit event a 60-second hang bound (`LibraryStoreRelocationTests`,
  `ProfileDataRevisionAuditRegressionTests`). `8c88e71` makes
  `LibraryStoreImportIntegrationTests.testImportedLaunchCannotOpenBeforeFingerprintReview`
  await review and prepared-launch events. These changes remove short timing
  assumptions in those tests, not all wall-clock bounds in the suite.
  `75d4a3e` adds `LaunchPresentationAuditRegressionTests`, including
  `testChooseApplicationUsesSceneBindingWithoutApplicationOrTabSelection`,
  `testApplicationImporterStateIsSharedBySceneBindingsAndIsolatedBetweenScenes`,
  and `testRepeatedDiagnosticWarningsUseUniqueListIdentities`. All 14 local
  gates passed at `8c88e71`; full suite: 2,121 tests, 0 failures, 2 skipped.

## PRX-039 — Confirmed Claude launches were rejected by a partial fingerprint rebuild

- **Category:** Reliability / Launch confirmation
- **Status:** Verified
- **Severity:** P1
- **Likelihood:** High when confirming a Claude launch
- **Confidence:** High
- **Evidence:** `LibraryStore.currentLaunchTarget(for:)` rebuilt a
  `LaunchConfigurationSource` without `requiresClaudeConfigIsolation`, whose
  default is false. The original Claude request set it to true and
  `LaunchConfigurationFingerprintFactory` hashes it, so confirmation compared
  different fingerprints even when the configuration had not changed.
- **Affected components:** launch confirmation and recovery fingerprints.
- **Reproduction / scenario:** Enable confirmation, open an unchanged Claude
  space, and confirm the pending launch.
- **Impact:** The confirmed launch was rejected as a changed configuration.
- **Root cause:** A partial copy omitted an isolation field from the source
  used to rebuild the fingerprint.
- **Proposed fix:** Preserve the complete launch source and change only the
  revision used for comparison; use the same source builder for recovery.
- **Required tests:** confirmed Claude and Chromium requests retain every
  fingerprint field; recovery fingerprint matches the complete source.
- **Dependencies:** None
- **Estimated complexity:** Small
- **Resolution / verification:** Fixed in `75d4a3e`, immediately before and
  included in `d09732e`. `git log -S requiresClaudeConfigIsolation` traces the
  field and fingerprint coverage to `57f11c6` and `74b2913`; the `75d4a3e`
  diff replaces the partial rebuild in `Stores/LibraryStore+LaunchRequests.swift`
  and the recovery rebuild in
  `Stores/LibraryStore+LaunchLifecycleEvents.swift`.
  Test:
  `PresetIntegrationAuditRegressionTests.testConfirmedClaudeAndChromiumRequestsRetainEveryFingerprintField`.
  Full suite at `8c88e71`: 2,121 tests, 0 failures, 2 skipped.
