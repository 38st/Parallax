# Production-readiness gap register

This is the authoritative findings ledger, last refreshed August 20, 2026.
“Verified” means the locally actionable change is implemented and tested; it
does not imply that external signing or publication was authorized.

## PRX-001 — Managed crashes lacked attribution and controlled recovery

- **Category:** Reliability / Observability
- **Status:** Verified
- **Severity:** P1
- **Likelihood:** High; observed incident
- **Confidence:** High
- **Evidence:** Previously every termination was presented as closed. Lifecycle
  disposition, observed PID fallback, strict crash-report matching, and recovery
  now live in `ApplicationLauncher.swift`, `LaunchHistoryStore.swift:32-48`,
  `ApplicationCrashReportLocator.swift:84-166`, and
  `LibraryStore.swift:3481-3600`.
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
  opt-out setting, strict report matching, “Ended Unexpectedly” UI, and exact
  Parallax-quit disposition. Relevant tests pass as part of the 1,204-test
  warning-clean suite.

## PRX-002 — Durable activity protection could silently degrade

- **Category:** Reliability / Data integrity / Observability
- **Status:** Verified
- **Severity:** P1
- **Likelihood:** Low to medium
- **Confidence:** High
- **Evidence:** Bootstrap previously used unannotated `try?` fallbacks.
  `ParallaxApp.swift:15-58` now preserves the initialization error and
  `LibraryStore.swift:482-505` fails closed.
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
  passes.

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
  hardening, UI, and two regression tests are implemented.

## PRX-004 — Release artifact and signed distribution gate

- **Category:** Build / Release
- **Status:** Blocked by an explicit external dependency or decision
- **Severity:** P1 for public distribution; not a source-RC defect
- **Likelihood:** Certain until release authorization
- **Confidence:** High
- **Evidence:** Packaging integration built and verified a local app, ZIP, DMG,
  signatures, provenance, collision handling, and isolated
  install/upgrade/rollback. Release mode rejects dirty source and missing
  credentials before artifact mutation.
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
  passed. Public release remains NO-GO.

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
  pass.

## PRX-006 — Secrets in launch arguments escaped the environment model

- **Category:** Security / Privacy
- **Status:** Verified
- **Severity:** P1
- **Likelihood:** Medium
- **Confidence:** High
- **Evidence:** Argument text was persisted, previewed, exported, and passed via
  argv. `SensitiveLaunchArgumentPolicy` in
  `SecretConfiguration.swift:322-417` now detects secret-shaped options,
  credential URLs, and Keychain references; compiler and export paths consume
  it.
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
  configuration regression tests pass.

## PRX-007 — Release mode accepted a dirty source tree

- **Category:** Build / Release / Supply-chain integrity
- **Status:** Verified
- **Severity:** P1
- **Likelihood:** Medium
- **Confidence:** High
- **Evidence:** `script/build_and_run.sh:333-358,944` now requires a valid HEAD
  and empty porcelain status before release; archive mode remains usable for
  candidate testing.
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
- **Resolution / verification:** Packaging contract suite now passes 4/4,
  including dirty-tree rejection.

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
  filesystem-adversary tests pass.

## PRX-009 — Successful app open could be reported as failed while still running

- **Category:** Reliability / UX
- **Status:** Verified
- **Severity:** P1
- **Likelihood:** Low to medium
- **Confidence:** High
- **Evidence:** A process-identity registration error previously canceled
  observation and released the lease after `NSWorkspace` had already opened the
  app. `ApplicationLauncher.swift:335-381` now enters `runningDegraded`.
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
- **Resolution / verification:** Updated lifecycle regression passes.

## PRX-010 — One process could be attributed to multiple profiles

- **Category:** Isolation / Data integrity
- **Status:** Verified
- **Severity:** P1
- **Likelihood:** Low
- **Confidence:** High
- **Evidence:** In-memory PID mapping could overwrite prior identity.
  `DurableLaunchActivityStore.swift:276-319` now rejects a
  `ProcessStartIdentity` already owned by another request.
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
  and PID-reuse tests pass.

## PRX-011 — Identity-scoped launch ambiguity blocked the whole library

- **Category:** Reliability / Containment
- **Status:** Verified
- **Severity:** P1
- **Likelihood:** Low to medium after an interrupted open
- **Confidence:** High
- **Evidence:** Reconciliation treated any `.opening` receipt without a process
  identity as global ambiguity. `ProfileActivityRegistry.swift:61-66,303-320`
  now separates target-scoped ambiguity from genuinely global ambiguity.
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

## PRX-012 — Unsaved editor drafts could be lost or stale settings opened

- **Category:** UX / Data integrity
- **Status:** Verified
- **Severity:** P1
- **Likelihood:** High during normal editing
- **Confidence:** High
- **Evidence:** `ProfileEditorView` held the draft only in local `@State` while
  profile-list Open launched the persisted row. `LibraryStore.swift:130-139,
  2638-2684` now retains drafts by identity and blocks stale list launches.
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
  pass.

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
  tests verify merge and clear semantics.

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
  and diagnostic-token tests pass.

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
  usable and remains fail-closed.

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
- **Root cause:** Unit/presentation coverage is stronger than UI automation.
- **Proposed fix:** Confirm destructive template actions, centralize transient
  errors, complete localization, and add XCUITest journeys.
- **Required tests:** VoiceOver labels, keyboard-only flows, focus restoration,
  localization snapshots, and destructive confirmations.
- **Dependencies:** Localization review and UI-test host stability.
- **Estimated complexity:** Medium to large
- **Resolution / verification:** Template deletion now requires an explicit
  destructive confirmation. New-space and editor actions have standard
  cancel/default/save keyboard shortcuts. Critical automation identifiers are
  centralized in `UIAutomationContract` and uniqueness-tested so labels can be
  translated without breaking automation. The primary create/open/recovery/
  support labels have Spanish translations with a resource regression test.
  The critical state transitions remain covered by store and presentation
  integration tests; a host-driven visual snapshot/XCUITest suite remains
  useful non-blocking expansion work.

## PRX-017 — Mobile prototype is not release-complete

- **Category:** Product scope / Build
- **Status:** Deferred with rationale
- **Severity:** P2 in repository; out of scope for macOS RC
- **Likelihood:** Certain
- **Confidence:** High
- **Evidence:** `ParallaxMobile/README.md` labels the target a prototype. Its
  simulator build and two tests pass, but production capabilities, security,
  migrations, and release operations are not established.
- **Affected components:** `ParallaxMobile/`.
- **Reproduction / scenario:** Treat the prototype as a supported shipping
  product.
- **Impact:** False platform promises.
- **Root cause:** Prototype and macOS application share a repository.
- **Proposed fix:** Keep it excluded until a separate readiness plan defines
  product scope and gates.
- **Required tests:** Separate mobile critical-journey, security, persistence,
  device, signing, and distribution suites.
- **Dependencies:** Product scope decision.
- **Estimated complexity:** Large
- **Resolution / verification:** Explicitly excluded from this release.

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
  byte-identical ZIP hashes. Developer ID release ZIPs retain Apple-specific
  metadata and notarization tickets via `ditto`; signed ZIP/DMG bytes include
  authority timestamps and are independently ticket/content/hash verified.

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
  Restart/multi-store circuit and corrupt-ledger regression tests pass.
