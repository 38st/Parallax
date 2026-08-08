# Parallax delivery ledger

Last reconciled: August 8, 2026
Planning baseline: `bc1df031e9a89ac470cb8dc5ad5aae978fdf774d`

This is the current dependency-ordered delivery ledger for Parallax. Historical
findings under `docs/production-readiness/` and the preserved
`wip/parallax-product-run-20260729` branch remain useful evidence, but their
dates, test counts, and architecture descriptions are not current completion
proof.

## Status language

- **Verified:** implemented on the integration branch and supported by current
  focused and broad evidence.
- **In progress:** assigned with exclusive file ownership.
- **Pending:** accepted work whose dependencies are not complete.
- **Deferred:** deliberately outside the accepted release scope with a recorded
  re-entry gate.
- **External:** requires credentials, hardware, repository administration, or
  publication authority that is not stored in this repository.

Product-decision status and implementation status are separate. An accepted or
deferred product decision does not make its implementation or documentation
task Verified.

## Historical SHA-bound baseline

The following observations were recorded for clean `master` at
`bc1df031e9a89ac470cb8dc5ad5aae978fdf774d`, before the current Wave 1 working
changes. They are historical planning evidence, not proof for the present
working tree or any pending task. Every affected gate must be rerun and bound to
the final integration SHA.

| Evidence | Result at `bc1df03` |
| --- | --- |
| Working tree | Clean `master`, synchronized with `origin/master` at capture |
| Local tests | 624/624 passing |
| Warning-clean release build | Passing |
| ASan / TSan | 624/624 passing locally in each lane |
| Secret scan | Gitleaks 8.30.1, zero findings |
| Product-only coverage | 53.03% source lines; no ratchet yet |
| Packaging contracts | 4/4 passing |
| Native packaging integration | 5/5 passing |
| GitHub issues | One open: ShellWordsParser regression coverage |
| Exact-baseline GitHub CI | Missing; latest green run at capture targeted `b083790` |
| Tags / releases | None |

## Product decisions

| ID | Decision | Decision status | Decision evidence |
| --- | --- | --- | --- |
| PROD-001 | Support the macOS Local Spaces launcher and truthful local account tracking. | Accepted | `docs/PRODUCT_CONTRACT.md` records the decision; implementation and documentation remain gated by `DOC-001`, `CORP-SEC-001`, and `CORP-UX-001`. |
| PROD-002 | Defer enterprise organization seats, member recommendations, and provider-side allocation mutation until supported provider capabilities, organizational persistence, authorization, and reconciliation exist. | Deferred | Product contract records the exclusion and re-entry criteria; `DOC-001` verifies reachable claims. |
| PROD-003 | Formally defer the iPhone prototype and keep its source/release train separate. | Deferred | `docs/MOBILE_STATUS.md` records `feb7daa` and re-entry gates; preservation remains tracked by `GIT-004`. |
| PROD-004 | Keep public binary distribution NO-GO until the signed release gate passes. | Accepted constraint | Product contract records the constraint; `REL-004` through `REL-007` remain incomplete. |

## Wave 1 — truthfulness and immediate security

| ID | Outcome | Dependencies | Status | Verification |
| --- | --- | --- | --- | --- |
| PARSER-001 | Add exact `ShellWordsParser.parseResult` regression coverage and close GitHub issue #1. | None | In progress | Planned: `swift test --filter ShellWordsParserTests`; `swift test`; `gh issue view 1 --json number,state,url`. Results, integration CI, and issue closure are pending. |
| CORP-SEC-001 | Provider CLI execution uses trusted executable discovery, a minimal environment, bounded redacted errors, and validated authentication URLs. | PROD-001 | In progress | Planned: `swift test --filter AIAccountConnectionServiceTests`; `swift test`. Final integration results and CI are pending. |
| CORP-UX-001 | Account-isolation copy distinguishes Codex account homes from the single ambient Claude Code identity. | PROD-001 | In progress | Planned: `swift test --filter CorporateAccountIsolationPresentationTests`; `swift test --filter Corporate`; `swift test`. Final integration results and CI are pending. |
| PKG-001 | ZIP and DMG verification rejects unexpected top-level payloads. | None | In progress | Planned: `./script/test_build_and_run.sh`; `PARALLAX_PACKAGING_INTEGRATION=1 PARALLAX_PACKAGING_ARCHITECTURE=native ./script/test_build_and_run.sh`. Final integration results and CI are pending. |
| DOC-001 | Replace stale product claims with the current product contract and mobile status. | None | In progress | Planned: `git diff --check -- README.md docs/PRODUCT_CONTRACT.md docs/MOBILE_STATUS.md docs/DELIVERY_LEDGER.md docs/MASTER_EXECUTION_PROMPT.md`; `rg -n -e seat -e member -e allocation -e Claude -e reset -e mobile -e iPhone -e release README.md docs/PRODUCT_CONTRACT.md docs/MOBILE_STATUS.md`. Final reachability rereview and integration evidence are pending. |

## Wave 2 — CI truth and low-conflict dormant ports

| ID | Outcome | Dependencies | Status |
| --- | --- | --- | --- |
| CI-001 | Enforce warnings-as-errors in ordinary CI. | PARSER-001, CORP-SEC-001, CORP-UX-001, PKG-001, DOC-001 | Pending |
| CI-002 | Add pinned secret scanning with retained reports. | PARSER-001, CORP-SEC-001, CORP-UX-001, PKG-001, DOC-001 | Pending |
| CI-003 | Add product-only coverage reporting and an initial non-regression ratchet. | PARSER-001, CORP-SEC-001, CORP-UX-001, PKG-001, DOC-001 | Pending |
| CI-004 | Add source-to-catalog localization completeness checks. | DOC-001, CORP-UX-001 | Pending |
| CI-005 | Add separate ASan and TSan lanes. | CI-001 | Pending |
| NAME-001 | Port canonical display-name validation and enforce it at app, template, and space mutation boundaries. | PARSER-001, CORP-SEC-001, CORP-UX-001, PKG-001, DOC-001 | Pending |
| PROV-001 | Port the pure exact-process provenance classifier and pre-open snapshotter. | PARSER-001, CORP-SEC-001, CORP-UX-001, PKG-001, DOC-001 | Pending |
| KEY-TEST-001 | Add randomized production Keychain CRUD characterization without touching real records. | PARSER-001, CORP-SEC-001, CORP-UX-001, PKG-001, DOC-001 | Pending |
| ACCT-FRESH-001 | Distinguish last successful refresh from last attempt, visibly mark retained values stale after failure or age expiry, and never present fallback values as current provider truth. | CORP-SEC-001, CORP-UX-001 | Pending |

## Wave 3 — process identity and lifecycle

| ID | Outcome | Dependencies | Status |
| --- | --- | --- | --- |
| PROV-002 | Bind the returned `NSWorkspace` process to an exact pre/post-open provenance result. | PROV-001 | Pending |
| PROV-003 | Supervise exact PID/start/bundle identity and add a liveness fallback for missed termination notifications. | PROV-002 | Pending |
| PROV-004 | Require exact identity for activation, cooperative quit, lifecycle association, and store lookup. | PROV-003 | Pending |
| SINGLE-001 | Refuse a pre-existing singleton by default rather than claiming a newly isolated space; present a truthful recovery message. | PROV-002 | Pending |
| ADAPTER-001 | Verify created, self-exiting, singleton, activation, and quit behavior with harmless disposable application fixtures. | PROV-004 | Pending |

The default singleton policy is fail-closed refusal. A future degraded
bring-forward mode requires a separate explicit product decision and must never
claim delivery of the requested arguments, environment, or isolation.

## Wave 4 — versioned settings

| ID | Outcome | Dependencies | Status |
| --- | --- | --- | --- |
| SET-001 | Port the bounded versioned settings document, codec, and strict JSON preflight. | CI-001 | Pending |
| SET-002 | Port restrictive inspection, mutation locking, and locked primary inspection. | SET-001 | Pending |
| SET-003 | Port revision/digest CAS publication and restart-safe residual inventory. | SET-002 | Pending |
| SET-004 | Port exact legacy snapshot, decoder, compatibility assessment, and current-primary assessment. | SET-003 | Pending |
| SET-005 | Implement fail-closed legacy cutover, quarantine, and recovery. | SET-004 | Pending |
| SET-006 | Move the runtime `AppSettings` facade to verified off-main commits and surface conflicts/recovery. | SET-005 | Pending |

Settings migration policy: preserve exact legacy evidence, prefer a valid
current versioned primary, never overwrite corrupt/future/unknown data, and
publish a migration only under the settings mutation lock after same-lease
recapture.

## Wave 5 — Keychain ownership and ordinary revisions

| ID | Outcome | Dependencies | Status |
| --- | --- | --- | --- |
| REV-001 | Snapshot exact prior library/settings bytes before ordinary publication. | SET-006 | Pending |
| REV-002 | Add bounded count/byte/age retention, verified diff, and restore-as-new-revision. | REV-001 | Pending |
| KEY-001 | Migrate to the data-protection Keychain with bounded legacy fallback and conflict-safe rollback. | KEY-TEST-001, SET-006 | Pending |
| KEY-002 | Inventory references across the current library, settings/templates, revisions, drafts, imports, and journals. | REV-002, KEY-001 | Pending |
| KEY-003 | Add durable idempotent cleanup receipts and a retry/reconciliation worker. | KEY-002 | Pending |
| KEY-004 | Integrate safe cleanup with duplicate, edit, remove, import, restore, and draft discard. | KEY-003 | Pending |
| ACCT-DATA-001 | Define and implement `AccountSessions` retention, sign-out/removal/delete semantics, exact-root containment, recovery evidence, and user-visible storage governance without silently deleting provider credentials. | ACCT-FRESH-001, SET-006, KEY-001 | Pending |

Revision defaults are deliberately bounded: retain the newest 32 revisions for
up to 30 days and 128 MiB total, covering both library and settings metadata.
Future tuning must remain backward-compatible and cannot silently remove the
last known-good revision.

## Wave 6 — portable configuration and coherent backup

| ID | Outcome | Dependencies | Status |
| --- | --- | --- | --- |
| PORT-001 | Complete the portable settings schema, including crash recovery and visual identities. | SET-006 | Pending |
| PORT-002 | Add settings import review with explicit merge/replace and machine-root mapping. | PORT-001 | Pending |
| PORT-003 | Publish combined library/settings imports through one restart-safe transaction. | PORT-002 | Pending |
| BACK-001 | Define a versioned backup policy and quiescent immutable inventory. | PORT-003, KEY-004, PROV-004 | Pending |
| BACK-002 | Write, hash, verify, and atomically publish managed-data backup archives. | BACK-001 | Pending |
| BACK-003 | Restore transactionally after an immutable pre-restore backup, with deterministic crash recovery. | BACK-002, REV-002 | Pending |
| BACK-004 | Add recovery UI and maximum-size capacity/cancellation/tamper/failure evidence. | BACK-003 | Pending |

Combined settings imports default to a reviewed field-level merge. Machine-
specific roots require explicit mapping. Backups include library, settings,
managed profile data, and operation metadata; they exclude external data, app
binaries, and Keychain values. Backup archives must be encrypted when written
outside a user-selected local volume.

## Wave 7 — termination, accessibility, localization, and UI proof

| ID | Outcome | Dependencies | Status |
| --- | --- | --- | --- |
| TERM-001 | Coordinate Save/Discard/Cancel for dirty editors during window close and multi-window app quit. | SET-006, KEY-004 | Pending |
| A11Y-001 | Add deterministic focus entry/restoration and one-shot success/error announcements. | DOC-001, CORP-UX-001, ACCT-FRESH-001 | Pending |
| UX-RESP-001 | Make App Settings and account metrics scrollable/adaptive under long content and supported minimum sizes. | CORP-UX-001, ACCT-FRESH-001 | Pending |
| L10N-001 | Inventory and catalog the complete supported user-facing string surface. | DOC-001, CORP-UX-001, ACCT-FRESH-001 | Pending |
| L10N-002 | Complete English/Spanish parity, placeholder validation, and pseudolocalized long-text checks. | L10N-001 | Pending |
| UI-001 | Add a deterministic disposable macOS UI-test host and critical-journey suite. | TERM-001, A11Y-001, UX-RESP-001, L10N-002 | Pending |

## Wave 8 — packaging, governance, and release

| ID | Outcome | Dependencies | Status |
| --- | --- | --- | --- |
| PKG-002 | Add bounded raw ZIP/DMG structure, type, duplicate, normalization, size, ratio, permission, and mutation checks. | PKG-001 | Pending |
| PERF-001 | Add deterministic concurrency replay, supported-maximum performance, RSS, and disk budgets. | PROV-004, SET-006, KEY-004, BACK-004, TERM-001 | Pending |
| REL-001 | Record license, icon, screenshot, and asset provenance; add changelog and release notes. | UI-001, PERF-001, BACK-004, ACCT-DATA-001 | Pending |
| REL-002 | Generate an SBOM and authenticated source/artifact attestation. | PKG-002 | Pending |
| REL-003 | Separate ordinary CI from a protected manual release workflow that fails when required credentials are absent. | CI-005 | Pending |
| REL-004 | Freeze an exact clean source SHA and build universal artifacts once. | CI-005, UI-001, PERF-001, REL-001, REL-002, REL-003, PKG-002, BACK-004, ACCT-DATA-001 | Pending |
| REL-005 | Sign, notarize, staple, independently verify, and retain final artifacts. | REL-004 | External |
| REL-006 | Rehearse Finder/LaunchServices clean install, representative upgrade, Keychain continuity, and data-compatible rollback. | REL-005 | External |
| REL-007 | Tag, publish, redownload, and independently reverify the release. | REL-006 | External |

## Verification and acceptance evidence registry

Every Wave 1–8 task and GIT-001–005 has an evidence record below. A task may
move to **In progress** only after one owner receives exclusive write ownership
for the exact files. It may move to **Verified** only after its row contains:

- the final owned files and rollback procedure;
- literal focused and broad verification commands with results;
- the implementation commit;
- an independent reviewer who did not author the change;
- the exact green CI SHA and run URL, when the task affects CI-tested source;
- acceptance evidence tied to the task outcome; and
- explicit residual risk or `None identified`.

In this table, `—` means the evidence does not exist yet, not that the field is
inapplicable or passed. “Required” verification is a future acceptance gate and
does not claim that a command has run.

### Read-only audit exception

A task whose accepted outcome is exclusively a read-only inspection or
classification may be **Verified** without an implementation commit or CI run
only when all of the following are true:

- its scope forbids source, ref, worktree, stash, or external-state mutation;
- its evidence records the literal commands, exact inputs or refs, and results;
- an independent reviewer who did not author the inspected state records a
  disposition;
- the Commit and CI fields say `N/A — read-only audit` rather than `—`; and
- any preservation, integration, or destructive cleanup is tracked separately
  and remains subject to its ordinary gates.

This exception applies to GIT-002 only. It does not waive implementation,
review, CI, or acceptance evidence for a task that changes product code,
documentation, Git state, or an external system.

| ID | Owner / exclusive file scope | Risk / rollback | Required acceptance evidence | Commit | Independent reviewer | CI SHA / URL | Residual risk |
| --- | --- | --- | --- | --- | --- | --- | --- |
| PARSER-001 | Wave 1 parser writer; `Tests/ParallaxTests/ShellWordsParserTests.swift` | Additive test-only change; remove the file | Working tree contains four exact valid/unmatched-quote/trailing-escape cases. Planned: `swift test --filter ShellWordsParserTests`; `swift test`; `gh issue view 1 --json number,state,url`. Results, commit, CI, and issue closure remain pending. | — | — | — | Open issue and unintegrated test file |
| CORP-SEC-001 | Wave 1 provider-security writer; `Sources/Parallax/Services/AIAccountConnectionService.swift`, `Tests/ParallaxTests/AIAccountConnectionServiceTests.swift` | Provider sign-in regression; revert both files to the integration baseline | Working-tree implementation and hostile executable/environment/URL/output tests exist. Planned: `swift test --filter AIAccountConnectionServiceTests`; `swift test`. Final integration results, commit, and CI remain pending. | — | — | — | Provider CLI/version behavior still requires final integration evidence |
| CORP-UX-001 | Wave 1 account-copy writer; `Sources/Parallax/Views/CorporateControlCenterView.swift`, `Tests/ParallaxTests/CorporateAccountIsolationPresentationTests.swift` | Misleading account semantics; revert presentation slice | Working-tree provider-specific copy and presentation tests exist. Planned: `swift test --filter CorporateAccountIsolationPresentationTests`; `swift test --filter Corporate`; `swift test`. Final integration results, commit, and CI remain pending. | — | — | — | Account freshness remains tracked by ACCT-FRESH-001 |
| PKG-001 | Wave 1 packaging writer; `script/lib/build_and_run/artifact_verification.sh`, `script/test_build_and_run.sh` | Reject valid packages or miss hostile payloads; preserve current script diff and revert cohesive slice | Working-tree top-level ZIP/DMG rejection logic and hostile contract fixtures exist. Planned: `./script/test_build_and_run.sh`; `PARALLAX_PACKAGING_INTEGRATION=1 PARALLAX_PACKAGING_ARCHITECTURE=native ./script/test_build_and_run.sh`. Final results, commit, and CI remain pending. | — | — | — | Broader hostile structure work remains PKG-002 |
| DOC-001 | Documentation writer; `README.md`, `docs/PRODUCT_CONTRACT.md`, `docs/MOBILE_STATUS.md`, `docs/DELIVERY_LEDGER.md`, `docs/MASTER_EXECUTION_PROMPT.md` | Claims drift from reachable behavior; revert documentation slice | Reachability audit, SHA-bound baseline, product/mobile decisions, Claude ambient-sign-in warning, and evidence mechanism are present. Planned: `git diff --check -- README.md docs/PRODUCT_CONTRACT.md docs/MOBILE_STATUS.md docs/DELIVERY_LEDGER.md docs/MASTER_EXECUTION_PROMPT.md`; `rg -n -e seat -e member -e allocation -e Claude -e reset -e mobile -e iPhone -e release README.md docs/PRODUCT_CONTRACT.md docs/MOBILE_STATUS.md`. Final rereview, commit, and CI disposition remain pending. | — | — | — | Readiness-history refresh remains required at final SHA |
| CI-001 | Unassigned; `.github/workflows/ci.yml`, warning policy files | CI breakage; revert task commit | Warning fixture fails and warning-clean build/full suite pass | — | — | — | — |
| CI-002 | Unassigned; CI workflow and pinned scanner configuration | Supply-chain or false-positive failure; revert scanner lane | Pinned-version, finding, redaction, report-retention, and clean-tree fixtures | — | — | — | — |
| CI-003 | Unassigned; CI workflow and coverage scripts/configuration | Misleading denominator; revert ratchet | Literal product-only extraction, exclusions, baseline, regression failure, full suite | — | — | — | — |
| CI-004 | Unassigned; localization census scripts, catalogs, CI workflow | False completeness; revert parity gate | Missing/extra key and placeholder fixtures plus packaged-catalog validation | — | — | — | — |
| CI-005 | Unassigned; sanitizer workflow jobs and test configuration | Flaky/unsupported lane; revert jobs | Independent ASan and TSan runs with exact toolchain, logs, and supported exclusions | — | — | — | — |
| NAME-001 | Unassigned; name-validation support/model/view boundaries and tests | Reject valid historical names; revert boundary integrations | Unicode trim/reject matrix, repairability, app/template/space mutation tests, full suite | — | — | — | — |
| PROV-001 | Unassigned; process-provenance model/snapshotter and focused tests | Misclassification; revert additive classifier | New/pre-existing/indeterminate, PID reuse, race, and snapshot-failure tests | — | — | — | — |
| KEY-TEST-001 | Unassigned; Keychain adapter characterization tests/fixture namespace only | Real-record contact; stop test and remove randomized namespace | Disposable CRUD/update/delete/conflict matrix proving no production namespace access | — | — | — | — |
| ACCT-FRESH-001 | Unassigned; corporate account model/store/views and focused tests | Fresh data mislabeled stale or stale data trusted; revert compatible fields/UI | Success/failure/age/clock/restart tests and visible stale/failure semantics | — | — | — | — |
| PROV-002 | Unassigned; workspace launcher provenance binding and tests | False launch ownership; revert binding and retain fail-closed behavior | Pre/post snapshot, returned-process binding, singleton, ambiguity, and PID-reuse tests | — | — | — | — |
| PROV-003 | Unassigned; process observation/activity receipt and tests | Leaked or early-released lease; revert liveness fallback | Notification/poll race, missed notification, cancellation, exact-start, restart tests | — | — | — | — |
| PROV-004 | Unassigned; activation/quit/lifecycle/store lookup boundaries and tests | Wrong-process operation; revert exact-identity integrations | PID-reuse, bundle/start mismatch, cooperative quit, activation, and lookup tests | — | — | — | — |
| SINGLE-001 | Unassigned; launcher/store presentation and localized copy/tests | Blocks legitimate opens; revert policy while preserving truthful degraded status | Existing-singleton refusal, no false argument/environment claim, recovery UI tests | — | — | — | — |
| ADAPTER-001 | Unassigned; harmless fixture apps and production-adapter integration tests | Test affects installed apps; delete disposable fixtures and revert tests | Created/self-exit/singleton/activation/quit matrix in isolated roots | — | — | — | — |
| SET-001 | Unassigned; settings document/codec/preflight and tests | Decode incompatibility; revert additive format reader | Size/depth/type/version/duplicate/strict-JSON fixtures and round-trip | — | — | — | — |
| SET-002 | Unassigned; settings inspection/lock authority and tests | Lockout or unsafe read; revert lock layer | No-follow modes, contention, ancestor swap, locked inspection, failure tests | — | — | — | — |
| SET-003 | Unassigned; settings repository/CAS/residual inventory and tests | Lost update; restore prior bytes and revert publisher | Two-writer CAS, digest, interruption, residual recovery, permission tests | — | — | — | — |
| SET-004 | Unassigned; legacy snapshot/decoder/assessment and fixtures | Legacy evidence altered; revert read-only adapters | Exact-byte snapshot and absent/corrupt/future/precedence compatibility matrix | — | — | — | — |
| SET-005 | Unassigned; settings migration/quarantine/recovery and tests | Data loss on cutover; restore preserved legacy bytes and revert migrator | Same-lease recapture, crash points, corrupt/future quarantine, idempotent recovery | — | — | — | — |
| SET-006 | Unassigned; `AppSettings` facade/repository/UI and tests | Runtime conflicts or UI stalls; revert facade, retain versioned evidence | Off-main commit, stale writer, restart, conflict/recovery UI, full suite | — | — | — | — |
| REV-001 | Unassigned; revision snapshot store/publication hook and tests | Publication without prior snapshot; revert hook, retain snapshots | Exact prior library/settings bytes, crash-before/after-hook, permission tests | — | — | — | — |
| REV-002 | Unassigned; revision retention/diff/restore and tests | Prunes last good state; disable pruning and revert task | Count/byte/age bounds, tamper, diff, restore-as-new, failure injection | — | — | — | — |
| KEY-001 | Unassigned; Keychain adapter/migration and focused tests | Credential loss; retain legacy item and revert migration | Data-protection access, bounded fallback, conflict, rollback, randomized integration | — | — | — | — |
| KEY-002 | Unassigned; reference inventory across stores/imports/drafts/journals and tests | Live secret misclassified orphan; revert inventory consumers | Shared/unknown/corrupt reference graphs and conservative retention tests | — | — | — | — |
| KEY-003 | Unassigned; cleanup receipt repository/worker and tests | Premature or repeated deletion; stop worker and retain receipt | Idempotence, crash/restart, contention, corrupt receipt, retry tests | — | — | — | — |
| KEY-004 | Unassigned; edit/duplicate/remove/import/restore/draft integrations and tests | Secret loss across workflow; revert integration, retain pending receipts | Every mutation path, shared-reference, failure, restart, multiwindow tests | — | — | — | — |
| ACCT-DATA-001 | Unassigned; `AccountSessions` repository/lifecycle UI/docs and tests | Provider credential loss or indefinite retention; fail closed and preserve exact session root | Retention/sign-out/remove/delete, containment, symlink, crash/recovery, disclosure tests | — | — | — | — |
| PORT-001 | Unassigned; portable settings schema/codec and tests | Incomplete export; revert schema version, preserve bytes | All settings fields, unknown/future members, round-trip, redaction tests | — | — | — | — |
| PORT-002 | Unassigned; settings import review/model/UI and tests | Machine-specific path misuse; cancel import and retain originals | Merge/replace, root mapping, conflict, invalid/future, cancel tests | — | — | — | — |
| PORT-003 | Unassigned; combined import transaction/recovery and tests | Split-brain library/settings; recover journal and revert coordinator | Crash at every publication boundary, CAS conflict, restart, exact rollback | — | — | — | — |
| BACK-001 | Unassigned; backup policy/inventory and tests/docs | Inconsistent or overbroad inventory; abort before archive | Quiescence, exact ownership, exclusions, capacity and cancellation planning tests | — | — | — | — |
| BACK-002 | Unassigned; archive writer/verifier/publication and tests | Corrupt or plaintext-sensitive backup; remove unpublished archive | Hash/tamper/encryption/atomicity/permissions/maximum-size tests | — | — | — | — |
| BACK-003 | Unassigned; restore transaction/recovery and tests | Irrecoverable overwrite; restore immutable pre-restore backup | Crash matrix, tamper, wrong version, rollback, idempotent restart tests | — | — | — | — |
| BACK-004 | Unassigned; backup/recovery UI, capacity/failure tests | Misleading completion or frozen UI; revert UI, preserve transaction | Progress/cancel/error/retry, long operation, max-size and manual recovery journeys | — | — | — | — |
| TERM-001 | Unassigned; app/window termination coordinator, editor integrations, tests | Silent draft/secret loss; cancel termination and revert coordinator | Cmd-W/Cmd-Q Save/Discard/Cancel, failed save, conflict, cleanup/retry tests | — | — | — | — |
| A11Y-001 | Unassigned; focus/announcement presentation and tests | Focus trap or duplicate announcement; revert modifiers | Keyboard focus entry/restore, one-shot success/error, reduced-motion/VoiceOver review | — | — | — | — |
| UX-RESP-001 | Unassigned; App Settings/account metric layout and tests | Controls inaccessible at minimum size; revert layout | Minimum/large/long-text/light/dark layouts and keyboard reachability | — | — | — | — |
| L10N-001 | Unassigned; source census/catalogs/parity tests | Missing user-facing strings; revert catalog batch | Complete source census, packaged resource lookup, placeholder parity | — | — | — | — |
| L10N-002 | Unassigned; English/Spanish/pseudolocale catalogs and tests | Broken translation or truncation; revert catalog batch | Locale parity, placeholder types, pseudolocalized long-text visual/manual matrix | — | — | — | — |
| UI-001 | Unassigned; UI-test host/project, disposable fixtures, journey tests | Flaky host or real-data contact; disable host and remove fixture roots | Empty/create/open/edit/import/recovery/quit journeys under isolated data | — | — | — | — |
| PKG-002 | Unassigned; archive/DMG preflight/verifier and hostile fixtures | Reject valid artifacts or accept hostile input; revert verifier slice | Duplicate/type/path/normalization/size/ratio/mode/mutation fixtures and integration | — | — | — | — |
| PERF-001 | Unassigned; replay/performance harnesses and budgets | Flaky or unrealistic limits; revert budgets, retain diagnostic logs | Seeded concurrency replay and maximum-size time/RSS/disk measurements | — | — | — | — |
| REL-001 | Unassigned; provenance/license/changelog/release-note documents/assets | Incorrect ownership/version claim; revert metadata, do not release | License/asset source review, version consistency, release-note approval | — | — | — | — |
| REL-002 | Unassigned; SBOM/attestation generator and verification workflow | Unbound provenance; discard sidecars and revert generator | Deterministic SBOM, source/artifact digest binding, signature verification | — | — | — | — |
| REL-003 | Unassigned; ordinary/release workflows and protected-environment docs | Credential misuse or skipped-green release; disable workflow | Missing-credential failure, protected approval, artifact handoff, no-secret logs | — | — | — | — |
| REL-004 | Unassigned; release metadata and one-shot universal build invocation | Wrong or dirty source freeze; discard artifacts | Clean exact SHA, all prerequisite evidence, architectures, hashes, provenance | — | — | — | — |
| REL-005 | Authorized release operator; signing/notary credentials and immutable artifacts | Invalid public artifact; withhold publication | Developer ID, notary, staple, Gatekeeper, independent hash/signature verification | — | — | — | — |
| REL-006 | Authorized release operator; clean account/hardware and final artifacts | Upgrade or rollback data loss; stop rollout and restore retained artifact/data | Finder/LaunchServices install, representative upgrade, Keychain continuity, rollback | — | — | — | — |
| REL-007 | Authorized publisher; tag/release/download surfaces | Wrong public bytes; unpublish release and retain incident evidence | Protected tag, publication approval, redownload, independent final verification | — | — | — | — |
| GIT-001 | Lead integrator; dormant product branch plus task-specific port files | Lost or over-broad history integration; preserve refs and revert each bounded port | The 62-commit branch is preserved and classified for selective ports; wholesale merge remains prohibited and integration is incomplete | — | — | — | Valuable ports remain pending |
| GIT-002 | Read-only Git auditor; 41-file `Parallax-dev`/`stash@{0}` snapshot and the 14 blobs different from `master`; no writes | Audit omission; rerun the literal blob/inventory comparisons below without applying state | Commands and exact results below prove stash/worktree parity and classify all 14 master differences as superseded; no port required | N/A — read-only audit | `/root/git_archaeology_audit`; independent; APPROVE | N/A — read-only local Git/blob audit | Integration and authorized cleanup remain separate tasks under GIT-003–005 |
| GIT-003 | Lead integrator; `script/lib/build_and_run/artifact_verification.sh`, `script/test_build_and_run.sh` | Packaging behavior lost during integration; retain dirty source until a verified commit exists | Both script changes remain preserved in the working tree; focused packaging integration is pending | — | — | — | Uncommitted packaging behavior remains at risk until integrated |
| GIT-004 | Lead integrator; mobile commit `feb7daa` and archival ref only | Unique prototype commit becomes unreachable; retain existing branch and do not delete | Source commit `feb7daa` remains on `wip/parallax-mobile-prototype-20260729`; durable remote archival ref requires approval | `feb7daa` source commit; archival ref not created | — | — | Unique work is local until archival push is authorized |
| GIT-005 | Lead integrator after explicit approval; obsolete refs/worktrees/stash targets resolved from GIT-002 | Destructive loss; stop and preserve every target on ambiguity | Exact targets, ancestry, uniqueness, preservation ref, approval, and post-cleanup inventory are required; cleanup has not run | — | — | — | Destructive authorization unavailable |

### GIT-002 read-only audit evidence

The independent reviewer `/root/git_archaeology_audit` did not author the
snapshot or the `master` changes. The audit made no source, ref, worktree,
stash, or external-state mutation.

Literal stash/worktree parity command:

```zsh
dev_root=/Users/armanruzgar/dev/Parallax-dev
tracked_files=("${(@f)$(git -C "$dev_root" diff --name-only)}")
untracked_files=("${(@f)$(git -C "$dev_root" ls-files --others --exclude-standard)}")
integer mismatches=0
for relfile in $tracked_files; do
  worktree_blob=$(git -C "$dev_root" hash-object "$relfile")
  stash_blob=$(git rev-parse "stash@{0}:$relfile")
  [ "$worktree_blob" = "$stash_blob" ] || (( mismatches += 1 ))
done
for relfile in $untracked_files; do
  worktree_blob=$(git -C "$dev_root" hash-object "$relfile")
  stash_blob=$(git rev-parse "stash@{0}^3:$relfile")
  [ "$worktree_blob" = "$stash_blob" ] || (( mismatches += 1 ))
done
printf 'tracked=%d untracked=%d total=%d mismatches=%d\n' \
  ${#tracked_files} ${#untracked_files} \
  $(( ${#tracked_files} + ${#untracked_files} )) $mismatches
```

Recorded result: `tracked=35 untracked=6 total=41 mismatches=0`.

Literal master-difference command:

```zsh
dev_root=/Users/armanruzgar/dev/Parallax-dev
{ git -C "$dev_root" diff --name-only; git -C "$dev_root" ls-files --others --exclude-standard; } \
  | LC_ALL=C sort -u \
  | while IFS= read -r relfile; do
      worktree_blob=$(git -C "$dev_root" hash-object "$relfile")
      master_blob=$(git rev-parse "master:$relfile" 2>/dev/null || printf MISSING)
      [ "$worktree_blob" = "$master_blob" ] \
        || printf '%s\t%s\t%s\n' "$relfile" "$worktree_blob" "$master_blob"
    done
```

Recorded result: exactly 14 snapshot blobs differ from `master`:

| File | Snapshot blob | `master` blob |
| --- | --- | --- |
| `Sources/Parallax/App/ParallaxApp.swift` | `4fd57554385b2ecc51c5c88e7a0ff33a6d45329e` | `68b3a55837fc910f807b854270acd7d7eccedfba` |
| `Sources/Parallax/Stores/LibraryStore.swift` | `a39c239b31defd19fd5204d4144d60f2b0704ca8` | `205318ab283c03da9b13878349cec6bb5084df27` |
| `Sources/Parallax/Views/ApplicationHeaderView.swift` | `181e95f7a545b5d0f88dbe46322d0873f2cc7a02` | `26fdd85c594598624e518f3d47ea0a0f2658499d` |
| `Sources/Parallax/Views/ApplicationRemovalConfirmationView.swift` | `fdc3634d30aaedea9c6302bd79e908c8a51c7043` | `9687367b7b8fff9dfe34c00eddd26aa9eb4b17ef` |
| `Sources/Parallax/Views/CompactApplicationHeaderView.swift` | `d40223b101eb1770288ff79700872f2f1d7806f8` | `a836b208af88a63c11c0891b3de211d4165badf2` |
| `Sources/Parallax/Views/ContentView.swift` | `77e850cb9b9e91ad570be16c2f5401c0958b8929` | `1a7947c51394fc42235402f0f695ea67b0aa8687` |
| `Sources/Parallax/Views/DetailView.swift` | `ed2ec8a2b8f6cb37f46faca60fbc8654d290f034` | `740876086b2a4e6a13de222d95093d2f6f956565` |
| `Sources/Parallax/Views/NewSpaceView.swift` | `08190c503eaa34393b5fd183c53aaf52b47bba77` | `fa31f72cdbe95b64f20a6ad61140dcb62d1c5f39` |
| `Sources/Parallax/Views/ProfileEditorView.swift` | `b32c32cf291c9f67aad89b9fa3f3783d2f9b3c3b` | `1457bf6e3409be67375b1cd43633ed71de0e7df3` |
| `Sources/Parallax/Views/SettingsView.swift` | `529a5964a81cfc99d02a1b76b0cf0a784c6dab3d` | `115dc1a65105e16c06bec4d97f83b98b46afc5d6` |
| `Sources/Parallax/Views/SidebarView.swift` | `ab9c253b6fd5d7dd367aa7d087fc4284bb2a6ba5` | `0c462e6abb4b1bff02afc2aa9cab2bd7abe17727` |
| `Tests/ParallaxTests/LaunchProfileTests.swift` | `b02f8d774cc121bd46d16390c8cdad252895f1d3` | `b285d6cac7e5cc3ca8f424605353c6f6b941be26` |
| `Tests/ParallaxTests/LibraryStoreStartupRecoveryTests.swift` | `62c7b4c3ba6ab34e1c39dffe807c792ea9502265` | `c372e2c09d36d4ed88e775c407952c2f9daafd1f` |
| `Tests/ParallaxTests/LocalizationTests.swift` | `a2bdfab6505a0212eac5e1085edb3d0d89f97ca6` | `b1b007cf685987b462e4c0c47407c8c1f7d8da1a` |

Literal integration-history commands:

```zsh
git show -s --format='%H%n%P%n%s' be1bc11404ae6602a9f6a1cde6ce1f7253b389b0
git log --oneline --reverse \
  be1bc11404ae6602a9f6a1cde6ce1f7253b389b0..master -- \
  Sources/Parallax/Stores/LibraryStore.swift \
  Sources/Parallax/Views/ContentView.swift \
  Sources/Parallax/Views/ProfileEditorView.swift
for relfile in \
  Sources/Parallax/Stores/LibraryStore.swift \
  Sources/Parallax/Views/ContentView.swift \
  Sources/Parallax/Views/ProfileEditorView.swift; do
  printf '%s\t' "$relfile"
  git log -1 --format='%h %s' \
    be1bc11404ae6602a9f6a1cde6ce1f7253b389b0..master -- "$relfile"
done
```

Recorded result: `be1bc11404ae6602a9f6a1cde6ce1f7253b389b0`
is a direct child of `ba4edfbbc57bc8bb9c5055debe723e1541e3bcb7`
with subject `MAC-001: checkpoint integrated macOS candidate`. Eleven of the
14 `master` blobs equal `be1bc11` exactly. The remaining three changed later:
`LibraryStore.swift` and `ProfileEditorView.swift` through
`717d0f2 Refactor core stores and packaging scripts`, and `ContentView.swift`
through `7f0f8e9 Add corporate AI account control center`.

Disposition: **APPROVE** the classification that all 14 differing files are
superseded and require no code port. Commit and CI evidence are
`N/A — read-only local Git/blob audit; no source mutation and no CI-tested
change`. Preservation, integration, and any destructive cleanup remain
separately gated by GIT-003–005 and explicit destructive authorization.

## Repository preservation and cleanup

| ID | Outcome | Status |
| --- | --- | --- |
| GIT-001 | Preserve and port valuable work from the 62-commit product branch; never merge it wholesale. | In progress |
| GIT-002 | Audit the 14 stash/worktree files that do not match current master. | Verified — read-only inventory complete; preservation/integration outcomes are tracked by GIT-003–005. |
| GIT-003 | Preserve the dirty two-script packaging work until its behavior is integrated. | Pending |
| GIT-004 | Preserve mobile commit `feb7daa` on a durable non-release ref. | Pending approval to push a new archival ref |
| GIT-005 | Remove obsolete worktrees/branches only after unique work is preserved and with explicit destructive-cleanup approval. | Pending approval |

## Final completion gate

Repository/program delivery is complete only when every accepted non-External
item above is Verified or an explicitly Deferred product decision, the default
branch is clean and green at the exact final SHA, documentation matches
reachable behavior, no valuable local work is stranded, and each remaining
External item is part of the sole remaining class of work and has exact
credentials, authority, hardware, owner, commands, rollback, and acceptance
evidence recorded.

That milestone may support an exact external handoff, but it does not mean a
public release is complete. Public release is complete only when REL-005,
REL-006, and REL-007 are Verified with final signed/notarized artifact,
install/upgrade/rollback, publication, redownload, and independent verification
evidence.
